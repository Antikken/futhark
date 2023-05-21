{-# LANGUAGE TypeFamilies #-}

-- The idea is to perform distribution on one level at a time, and
-- produce "irregular Maps" that can accept and produce irregular
-- arrays.  These irregular maps will then be transformed into flat
-- parallelism based on their contents.  This is a sensitive detail,
-- but if irregular maps contain only a single Stm, then it is fairly
-- straightforward, as we simply implement flattening rules for every
-- single kind of expression.  Of course that is also somewhat
-- inefficient, so we want to support multiple Stms for things like
-- scalar code.
module Futhark.Pass.Flatten (flattenSOACs) where

import Control.Monad.Reader
import Control.Monad.State
import Data.Bifunctor (bimap, first, second)
import Data.Foldable
import Data.List.NonEmpty qualified as NE
import Data.Map qualified as M
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Tuple.Solo
import Debug.Trace
import Futhark.IR.GPU
import Futhark.IR.SOACS
import Futhark.MonadFreshNames
import Futhark.Pass
import Futhark.Pass.ExtractKernels.BlockedKernel (mkSegSpace, segScan)
import Futhark.Pass.ExtractKernels.ToGPU (scopeForGPU, soacsExpToGPU, soacsLambdaToGPU, soacsStmToGPU)
import Futhark.Pass.Flatten.Builtins
import Futhark.Pass.Flatten.Distribute
import Futhark.Tools
import Futhark.Transform.Rename
import Futhark.Transform.Substitute
import Futhark.Util.IntegralExp
import Prelude hiding (div, rem)

data FlattenEnv = FlattenEnv

newtype FlattenM a = FlattenM (StateT VNameSource (Reader FlattenEnv) a)
  deriving
    ( MonadState VNameSource,
      MonadFreshNames,
      MonadReader FlattenEnv,
      Monad,
      Functor,
      Applicative
    )

data IrregularRep = IrregularRep
  { -- | Array of size of each segment, type @[]i64@.
    irregularSegments :: VName,
    irregularFlags :: VName,
    irregularOffsets :: VName,
    irregularElems :: VName
  }

data ResRep
  = -- | This variable is represented
    -- completely straightforwardly- if it is
    -- an array, it is a regular array.
    Regular VName
  | -- | The representation of an
    -- irregular array.
    Irregular IrregularRep

newtype DistEnv = DistEnv {distResMap :: M.Map ResTag ResRep}

insertRep :: ResTag -> ResRep -> DistEnv -> DistEnv
insertRep rt rep env = env {distResMap = M.insert rt rep $ distResMap env}

insertReps :: [(ResTag, ResRep)] -> DistEnv -> DistEnv
insertReps = flip $ foldl (flip $ uncurry insertRep)

insertIrregular :: VName -> VName -> VName -> ResTag -> VName -> DistEnv -> DistEnv
insertIrregular ns flags offsets rt elems env =
  let rep = Irregular $ IrregularRep ns flags offsets elems
   in insertRep rt rep env

insertIrregulars :: VName -> VName -> VName -> [(ResTag, VName)] -> DistEnv -> DistEnv
insertIrregulars ns flags offsets bnds env =
  let (tags, elems) = unzip bnds
      mkRep = Irregular . IrregularRep ns flags offsets
   in insertReps (zip tags $ map mkRep elems) env

insertRegulars :: [ResTag] -> [VName] -> DistEnv -> DistEnv
insertRegulars rts xs =
  insertReps (zip rts $ map Regular xs)

instance Monoid DistEnv where
  mempty = DistEnv mempty

instance Semigroup DistEnv where
  DistEnv x <> DistEnv y = DistEnv (x <> y)

resVar :: ResTag -> DistEnv -> ResRep
resVar rt env = fromMaybe bad $ M.lookup rt $ distResMap env
  where
    bad = error $ "resVar: unknown tag: " ++ show rt

segsAndElems :: DistEnv -> [DistInput] -> (Maybe (VName, VName, VName), [VName])
segsAndElems env [] = (Nothing, [])
segsAndElems env (DistInputFree v _ : vs) =
  second (v :) $ segsAndElems env vs
segsAndElems env (DistInput rt _ : vs) =
  case resVar rt env of
    Regular v' ->
      second (v' :) $ segsAndElems env vs
    Irregular (IrregularRep segments flags offsets elems) ->
      bimap (mplus $ Just (segments, flags, offsets)) (elems :) $ segsAndElems env vs

type Segments = NE.NonEmpty SubExp

segmentsShape :: Segments -> Shape
segmentsShape = Shape . toList

segmentsDims :: Segments -> [SubExp]
segmentsDims = shapeDims . segmentsShape

segMap :: Traversable f => f SubExp -> (f SubExp -> Builder GPU Result) -> Builder GPU (Exp GPU)
segMap segments f = do
  gtids <- traverse (const $ newVName "gtid") segments
  space <- mkSegSpace $ zip (toList gtids) (toList segments)
  ((res, ts), stms) <- collectStms $ localScope (scopeOfSegSpace space) $ do
    res <- f $ fmap Var gtids
    ts <- mapM (subExpType . resSubExp) res
    pure (map mkResult res, ts)
  let kbody = KernelBody () stms res
  pure $ Op $ SegOp $ SegMap (SegThread SegVirt Nothing) space ts kbody
  where
    mkResult (SubExpRes cs se) = Returns ResultMaySimplify cs se

readInput :: Segments -> DistEnv -> [SubExp] -> DistInputs -> SubExp -> Builder GPU SubExp
readInput _ _ _ _ (Constant x) = pure $ Constant x
readInput segments env is inputs (Var v) =
  case lookup v inputs of
    Nothing -> pure $ Var v
    Just (DistInputFree arr _) ->
      letSubExp (baseString v) =<< eIndex arr (map eSubExp is)
    Just (DistInput rt _) -> do
      case resVar rt env of
        Regular arr ->
          letSubExp (baseString v) =<< eIndex arr (map eSubExp is)
        Irregular (IrregularRep _ flags offsets elems) ->
          undefined

readInputs :: Segments -> DistEnv -> [SubExp] -> DistInputs -> Builder GPU ()
readInputs segments env is = mapM_ onInput
  where
    onInput (v, DistInputFree arr _) =
      letBindNames [v] =<< eIndex arr (map eSubExp is)
    onInput (v, DistInput rt t) =
      case resVar rt env of
        Regular arr ->
          letBindNames [v] =<< eIndex arr (map eSubExp is)
        Irregular (IrregularRep _ _ offsets elems) -> do
          offset <- letSubExp "offset" =<< eIndex offsets (map eSubExp is)
          case arrayDims t of
            [num_elems] -> do
              let slice = Slice [DimSlice offset num_elems (intConst Int64 1)]
              letBindNames [v] $ BasicOp $ Index elems slice
            _ -> do
              num_elems <-
                letSubExp "num_elems" =<< toExp (product $ map pe64 $ arrayDims t)
              let slice = Slice [DimSlice offset num_elems (intConst Int64 1)]
              v_flat <-
                letExp (baseString v <> "_float") $ BasicOp $ Index elems slice
              letBindNames [v] . BasicOp $
                Reshape ReshapeArbitrary (arrayShape t) v_flat

transformScalarStms ::
  Segments ->
  DistEnv ->
  DistInputs ->
  [DistResult] ->
  Stms SOACS ->
  [VName] ->
  Builder GPU DistEnv
transformScalarStms segments env inps distres stms res = do
  vs <- letTupExp "scalar_dist" <=< renameExp <=< segMap segments $ \is -> do
    readInputs segments env (toList is) inps
    addStms $ fmap soacsStmToGPU stms
    pure $ subExpsRes $ map Var res
  pure $ insertReps (zip (map distResTag distres) $ map Regular vs) env

transformScalarStm ::
  Segments ->
  DistEnv ->
  DistInputs ->
  [DistResult] ->
  Stm SOACS ->
  Builder GPU DistEnv
transformScalarStm segments env inps res stm =
  transformScalarStms segments env inps res (oneStm stm) (patNames (stmPat stm))

distCerts :: DistInputs -> StmAux a -> DistEnv -> Certs
distCerts inps aux env = Certs $ map f $ unCerts $ stmAuxCerts aux
  where
    f v = case lookup v inps of
      Nothing -> v
      Just (DistInputFree vs _) -> vs
      Just (DistInput rt _) ->
        case resVar rt env of
          Regular vs -> vs
          Irregular r -> irregularElems r

-- | Only sensible for variables of segment-invariant type.
elemArr :: Segments -> DistEnv -> DistInputs -> SubExp -> Builder GPU VName
elemArr segments env inps (Var v)
  | Just v_inp <- lookup v inps =
      case v_inp of
        DistInputFree vs _ -> irregularElems <$> mkIrregFromReg segments vs
        DistInput rt _ -> case resVar rt env of
          Irregular r -> pure $ irregularElems r
          Regular vs -> irregularElems <$> mkIrregFromReg segments vs
elemArr segments _ _ se = do
  rep <- letExp "rep" $ BasicOp $ Replicate (segmentsShape segments) se
  dims <- arrayDims <$> lookupType rep
  n <- toSubExp "n" $ product $ map pe64 dims
  letExp "reshape" $ BasicOp $ Reshape ReshapeArbitrary (Shape [n]) rep

mkIrregFromReg ::
  Segments ->
  VName ->
  Builder GPU IrregularRep
mkIrregFromReg segments arr = do
  arr_t <- lookupType arr
  segment_size <-
    letSubExp "reg_seg_size" <=< toExp . product . map pe64 $
      drop (shapeRank (segmentsShape segments)) (arrayDims arr_t)
  segments_arr <-
    letExp "reg_segments" . BasicOp $
      Replicate (segmentsShape segments) segment_size
  num_elems <-
    letSubExp "reg_num_elems" <=< toExp $ product $ map pe64 $ arrayDims arr_t
  elems <-
    letExp "reg_elems" . BasicOp $
      Reshape ReshapeArbitrary (Shape [num_elems]) arr
  flags <- letExp "reg_flags" <=< segMap (Solo num_elems) $ \(Solo i) -> do
    flag <- letSubExp "flag" <=< toExp $ (pe64 i `rem` pe64 segment_size) .==. 0
    pure [subExpRes flag]
  offsets <- letExp "reg_offsets" <=< segMap (shapeDims (segmentsShape segments)) $ \is -> do
    let flat_seg_i =
          flattenIndex
            (map pe64 (shapeDims (segmentsShape segments)))
            (map pe64 is)
    offset <- letSubExp "offset" <=< toExp $ flat_seg_i * pe64 segment_size
    pure [subExpRes offset]
  pure $
    IrregularRep
      { irregularSegments = segments_arr,
        irregularFlags = flags,
        irregularOffsets = offsets,
        irregularElems = elems
      }

-- Get the irregular representation of a var.
getIrregRep :: Segments -> DistEnv -> DistInputs -> VName -> Builder GPU IrregularRep
getIrregRep segments env inps v =
  case lookup v inps of
    Just v_inp -> case v_inp of
      DistInputFree arr _ -> mkIrregFromReg segments arr
      DistInput rt _ -> case resVar rt env of
        Irregular r -> pure r
        Regular arr -> mkIrregFromReg segments arr
    Nothing -> do
      v' <-
        letExp (baseString v <> "_rep") . BasicOp $
          Replicate (segmentsShape segments) (Var v)
      mkIrregFromReg segments v'

-- Do 'map2 replicate ns A', where 'A' is an irregular array (and so
-- is the result, obviously).
replicateIrreg ::
  Segments ->
  DistEnv ->
  VName ->
  String ->
  IrregularRep ->
  Builder GPU IrregularRep
replicateIrreg segments env ns desc rep = do
  -- Replication does not change the number of segments - it simply
  -- makes each of them larger.

  num_segments <- arraySize 0 <$> lookupType ns

  -- ns multipled with existing segment sizes.
  ns_full <- letExp (baseString ns <> "_full") <=< segMap (Solo num_segments) $
    \(Solo i) -> do
      n <-
        letSubExp "n" =<< eIndex ns [eSubExp i]
      old_segment <-
        letSubExp "old_segment" =<< eIndex (irregularSegments rep) [eSubExp i]
      full_segment <-
        letSubExp "new_segment" =<< toExp (pe64 n * pe64 old_segment)
      pure $ subExpsRes [full_segment]

  (ns_full_flags, ns_full_offsets, ns_full_elems) <- doRepIota ns_full
  (_, _, flat_to_segs) <- doSegIota ns_full

  w <- arraySize 0 <$> lookupType ns_full_elems

  elems <- letExp (desc <> "_elems") <=< segMap (Solo w) $ \(Solo i) -> do
    -- Which segment we are in.
    segment_i <-
      letSubExp "segment_i" =<< eIndex ns_full_elems [eSubExp i]
    -- Size of original segment.
    old_segment <-
      letSubExp "old_segment" =<< eIndex (irregularSegments rep) [eSubExp segment_i]
    -- Index of value inside *new* segment.
    j_new <-
      letSubExp "j_new" =<< eIndex flat_to_segs [eSubExp i]
    -- Index of value inside *old* segment.
    j_old <-
      letSubExp "j_old" =<< toExp (pe64 j_new `rem` pe64 old_segment)
    -- Offset of values in original segment.
    offset <-
      letSubExp "offset" =<< eIndex (irregularOffsets rep) [eSubExp segment_i]
    v <-
      letSubExp "v"
        =<< eIndex (irregularElems rep) [toExp $ pe64 offset + pe64 j_old]
    pure $ subExpsRes [v]

  pure $
    IrregularRep
      { irregularSegments = ns_full,
        irregularFlags = ns_full_flags,
        irregularOffsets = ns_full_offsets,
        irregularElems = elems
      }

transformDistBasicOp ::
  Segments ->
  DistEnv ->
  ( DistInputs,
    DistResult,
    PatElem Type,
    StmAux (),
    BasicOp
  ) ->
  Builder GPU DistEnv
transformDistBasicOp segments env (inps, res, pe, aux, e) =
  case e of
    BinOp {} ->
      scalarCase
    CmpOp {} ->
      scalarCase
    ConvOp {} ->
      scalarCase
    UnOp {} ->
      scalarCase
    Assert {} ->
      scalarCase
    Opaque op se
      | Var v <- se,
        Just (DistInput rt_in _) <- lookup v inps ->
          -- TODO: actually insert opaques
          pure $ insertRep (distResTag res) (resVar rt_in env) env
      | otherwise ->
          scalarCase
    Reshape _ _ arr
      | Just (DistInput rt_in _) <- lookup arr inps ->
          pure $ insertRep (distResTag res) (resVar rt_in env) env
    Index arr slice
      | null $ sliceDims slice ->
          scalarCase
      | otherwise -> do
          -- Maximally irregular case.
          ns <- letExp "slice_sizes" <=< segMap segments $ \is -> do
            slice_ns <- mapM (readInput segments env (toList is) inps) $ sliceDims slice
            fmap varsRes . letTupExp "n" <=< toExp $ product $ map pe64 slice_ns
          (_n, offsets, m) <- exScanAndSum ns
          (_, _, repiota_elems) <- doRepIota ns
          flags <- genFlags m offsets
          elems <- letExp "elems" <=< renameExp <=< segMap (NE.singleton m) $ \is -> do
            segment <- letSubExp "segment" =<< eIndex repiota_elems (toList $ fmap eSubExp is)
            segment_start <- letSubExp "segment_start" =<< eIndex offsets [eSubExp segment]
            readInputs segments env [segment] inps
            -- TODO: multidimensional segments
            let slice' =
                  fixSlice (fmap pe64 slice) $
                    unflattenIndex (map pe64 (sliceDims slice)) $
                      subtract (pe64 segment_start) . pe64 $
                        NE.head is
            auxing aux $
              fmap (subExpsRes . pure) . letSubExp "v"
                =<< eIndex arr (map toExp slice')
          pure $ insertIrregular ns flags offsets (distResTag res) elems env
    Iota n (Constant x) (Constant s) Int64
      | zeroIsh x,
        oneIsh s -> do
          ns <- elemArr segments env inps n
          (flags, offsets, elems) <- certifying (distCerts inps aux env) $ doSegIota ns
          pure $ insertIrregular ns flags offsets (distResTag res) elems env
    Iota n x s it -> do
      ns <- elemArr segments env inps n
      xs <- elemArr segments env inps x
      ss <- elemArr segments env inps s
      (flags, offsets, elems) <- certifying (distCerts inps aux env) $ doSegIota ns
      (_, _, repiota_elems) <- doRepIota ns
      m <- arraySize 0 <$> lookupType elems
      elems' <- letExp "iota_elems_fixed" <=< segMap (Solo m) $ \(Solo i) -> do
        segment <- letSubExp "segment" =<< eIndex repiota_elems [eSubExp i]
        v' <- letSubExp "v" =<< eIndex elems [eSubExp i]
        x' <- letSubExp "x" =<< eIndex xs [eSubExp segment]
        s' <- letSubExp "s" =<< eIndex ss [eSubExp segment]
        fmap (subExpsRes . pure) . letSubExp "v" <=< toExp $
          primExpFromSubExp (IntType it) x'
            ~+~ sExt it (untyped (pe64 v'))
              ~*~ primExpFromSubExp (IntType it) s'
      pure $ insertIrregular ns flags offsets (distResTag res) elems' env
    Replicate (Shape [n]) (Var v) -> do
      ns <- elemArr segments env inps n
      rep <- getIrregRep segments env inps v
      rep' <- replicateIrreg segments env ns (baseString v) rep
      pure $ insertRep (distResTag res) (Irregular rep') env
    Replicate (Shape [n]) (Constant v) -> do
      ns <- elemArr segments env inps n
      (flags, offsets, elems) <-
        certifying (distCerts inps aux env) $ doSegIota ns
      w <- arraySize 0 <$> lookupType elems
      elems' <- letExp "rep_const" $ BasicOp $ Replicate (Shape [w]) (Constant v)
      pure $ insertIrregular ns flags offsets (distResTag res) elems' env
    Copy v ->
      case lookup v inps of
        Just (DistInputFree v' _) -> do
          v'' <- letExp (baseString v' <> "_copy") $ BasicOp $ Copy v'
          pure $ insertRegulars [distResTag res] [v''] env
        Just (DistInput rt _) ->
          case resVar rt env of
            Irregular r -> do
              let name = baseString (irregularElems r) <> "_copy"
              elems_copy <- letExp name $ BasicOp $ Copy $ irregularElems r
              let rep = Irregular $ r {irregularElems = elems_copy}
              pure $ insertRep (distResTag res) rep env
            Regular v' -> do
              v'' <- letExp (baseString v' <> "_copy") $ BasicOp $ Copy v'
              pure $ insertRegulars [distResTag res] [v''] env
        Nothing -> do
          v' <-
            letExp (baseString v <> "_copy_free") . BasicOp $
              Replicate (segmentsShape segments) (Var v)
          pure $ insertRegulars [distResTag res] [v'] env
    Update _ as slice (Var v)
      | Just as_t <- distInputType <$> lookup as inps -> do
          ns <- letExp "slice_sizes"
            <=< renameExp
            <=< segMap (shapeDims (segmentsShape segments))
            $ \is -> do
              readInputs segments env is $
                filter ((`elem` sliceDims slice) . Var . fst) inps
              n <- letSubExp "n" <=< toExp $ product $ map pe64 $ sliceDims slice
              pure [subExpRes n]
          -- Irregular representation of `as`
          IrregularRep shape flags offsets elems <- getIrregRep segments env inps as
          -- Inner indices (1 and 2) of `ns`
          (_, _, ii1_vss) <- doRepIota ns
          (_, _, ii2_vss) <- certifying (distCerts inps aux env) $ doSegIota ns
          -- Number of updates to perform
          m <- arraySize 0 <$> lookupType ii2_vss
          elems' <- letExp "elems_scatter" <=< renameExp <=< genScatter elems m $ \gid -> do
            seg_i <- letSubExp "seg_i" =<< eIndex ii1_vss [eSubExp gid]
            in_seg_i <- letSubExp "in_seg_i" =<< eIndex ii2_vss [eSubExp gid]
            readInputs segments env [seg_i] $ filter ((/= as) . fst) inps
            v_t <- lookupType v
            let in_seg_is =
                  unflattenIndex (map pe64 (arrayDims v_t)) (pe64 in_seg_i)
                slice' = fmap pe64 slice
                flat_i =
                  flattenIndex
                    (map pe64 $ arrayDims as_t)
                    (fixSlice slice' in_seg_is)
            -- Value to write
            v' <- letSubExp "v" =<< eIndex v (map toExp in_seg_is)
            o' <- letSubExp "o" =<< eIndex offsets [eSubExp seg_i]
            -- Index to write `v'` at
            i <- letExp "i" =<< toExp (pe64 o' + flat_i)
            pure (i, v')
          pure $ insertIrregular shape flags offsets (distResTag res) elems' env
      | otherwise ->
          error "Flattening update: destination is not input."
    _ -> error $ "Unhandled BasicOp:\n" ++ prettyString e
  where
    scalarCase =
      transformScalarStm segments env inps [res] $
        Let (Pat [pe]) aux (BasicOp e)

-- Replicates inner dimension for inputs.
onMapFreeVar ::
  Segments ->
  DistEnv ->
  DistInputs ->
  VName ->
  (VName, VName, VName) ->
  VName ->
  Maybe (Builder GPU (VName, MapArray IrregularRep))
onMapFreeVar segments env inps ws (ws_flags, ws_offsets, ws_elems) v = do
  let segments_per_elem = ws_elems
  v_inp <- lookup v inps
  pure $ do
    ws_prod <- arraySize 0 <$> lookupType ws_elems
    fmap (v,) $ case v_inp of
      DistInputFree v' t -> do
        fmap (`MapArray` t) . letExp (baseString v <> "_rep_free_free_inp")
          <=< segMap (Solo ws_prod)
          $ \(Solo i) -> do
            segment <- letSubExp "segment" =<< eIndex segments_per_elem [eSubExp i]
            subExpsRes . pure <$> (letSubExp "v" =<< eIndex v' [eSubExp segment])
      DistInput rt t -> case resVar rt env of
        Irregular rep -> do
          offsets <- letExp (baseString v <> "_rep_free_irreg_offsets")
            <=< segMap (Solo ws_prod)
            $ \(Solo i) -> do
              segment <- letSubExp "segment" =<< eIndex ws_elems [eSubExp i]
              subExpsRes . pure <$> (letSubExp "v" =<< eIndex (irregularOffsets rep) [eSubExp segment])
          let rep' =
                IrregularRep
                  { irregularSegments = ws,
                    irregularFlags = irregularFlags rep,
                    irregularOffsets = offsets,
                    irregularElems = irregularElems rep
                  }
          pure $ MapOther rep' t
        Regular vs ->
          fmap (`MapArray` t) . letExp (baseString v <> "_rep_free_reg_inp")
            <=< segMap (Solo ws_prod)
            $ \(Solo i) -> do
              segment <- letSubExp "segment" =<< eIndex segments_per_elem [eSubExp i]
              subExpsRes . pure <$> (letSubExp "v" =<< eIndex vs [eSubExp segment])

onMapInputArr ::
  Segments ->
  DistEnv ->
  DistInputs ->
  SubExp ->
  Param Type ->
  VName ->
  Builder GPU (MapArray t)
onMapInputArr segments env inps w p arr =
  case lookup arr inps of
    Just v_inp ->
      case v_inp of
        DistInputFree vs t -> do
          v <-
            letExp (baseString vs <> "_flat") . BasicOp $
              Reshape ReshapeArbitrary (Shape [w]) vs
          pure $ MapArray v t
        DistInput rt t ->
          case resVar rt env of
            Irregular r -> do
              elems_t <- lookupType $ irregularElems r
              -- If parameter type of the map corresponds to the
              -- element type of the value array, we can map it
              -- directly.
              if stripArray (shapeRank (segmentsShape segments)) elems_t == paramType p
                then pure $ MapArray (irregularElems r) elems_t
                else -- Otherwise we need to perform surgery on the metadata.
                  pure $ MapOther undefined elems_t
            Regular vs ->
              undefined
    Nothing -> do
      arr_row_t <- rowType <$> lookupType arr
      arr_rep <-
        letExp (baseString arr <> "_inp_rep") . BasicOp $
          Replicate (segmentsShape segments) (Var arr)
      v <-
        letExp (baseString arr <> "_inp_rep_flat") . BasicOp $
          Reshape ReshapeArbitrary (Shape [w] <> arrayShape arr_row_t) arr_rep
      pure $ MapArray v arr_row_t

scopeOfDistInputs :: DistInputs -> Scope GPU
scopeOfDistInputs = scopeOfLParams . map f
  where
    f (v, inp) = Param mempty v (distInputType inp)

transformInnerMap ::
  Segments ->
  DistEnv ->
  DistInputs ->
  Pat Type ->
  SubExp ->
  [VName] ->
  Lambda SOACS ->
  Builder GPU (VName, VName, VName)
transformInnerMap segments env inps pat w arrs map_lam = do
  ws <- elemArr segments env inps w
  (ws_flags, ws_offsets, ws_elems) <- doRepIota ws
  new_segment <- arraySize 0 <$> lookupType ws_elems
  arrs' <-
    zipWithM
      (onMapInputArr segments env inps new_segment)
      (lambdaParams map_lam)
      arrs
  let free = freeIn map_lam
  free_sizes <-
    localScope (scopeOfDistInputs inps) $
      foldMap freeIn <$> mapM lookupType (namesToList free)
  let free_and_sizes = namesToList $ free <> free_sizes
  (free_replicated, replicated) <-
    fmap unzip . sequence $
      mapMaybe
        (onMapFreeVar segments env inps ws (ws_flags, ws_offsets, ws_elems))
        free_and_sizes
  free_ps <-
    zipWithM
      newParam
      (map ((<> "_free") . baseString) free_and_sizes)
      (map mapArrayRowType replicated)
  scope <- askScope
  let substs = M.fromList $ zip free_replicated $ map paramName free_ps
      map_lam' =
        substituteNames
          substs
          ( map_lam
              { lambdaParams = free_ps <> lambdaParams map_lam
              }
          )
      (distributed, arrmap) =
        distributeMap scope pat new_segment (replicated <> arrs') map_lam'
      m =
        transformDistributed arrmap (NE.singleton new_segment) distributed
  traceM $ unlines ["inner map distributed", prettyString distributed]
  addStms =<< runReaderT (runBuilder_ m) scope
  pure (ws_flags, ws_offsets, ws)

transformDistStm :: Segments -> DistEnv -> DistStm -> Builder GPU DistEnv
transformDistStm segments env (DistStm inps res stm) = do
  case stm of
    Let pat aux (BasicOp e) -> do
      let ~[res'] = res
          ~[pe] = patElems pat
      transformDistBasicOp segments env (inps, res', pe, aux, e)
    Let pat _ (Op (Screma w arrs form))
      | Just reds <- isReduceSOAC form,
        Just arrs' <- mapM (`lookup` inps) arrs,
        (Just (arr_segments, flags, offsets), elems) <- segsAndElems env arrs' -> do
          elems' <- genSegRed arr_segments flags offsets elems $ singleReduce reds
          pure $ insertReps (zip (map distResTag res) (map Regular elems')) env
      | Just (reds, map_lam) <- isRedomapSOAC form -> do
          map_pat <- fmap Pat $ forM (lambdaReturnType map_lam) $ \t ->
            PatElem <$> newVName "map" <*> pure (t `arrayOfRow` w)
          (ws_flags, ws_offsets, ws) <-
            transformInnerMap segments env inps map_pat w arrs map_lam
          let (redout_names, mapout_names) =
                splitAt (redResults reds) (patNames map_pat)
          elems' <-
            genSegRed ws ws_flags ws_offsets redout_names $
              singleReduce reds
          let (red_tags, map_tags) = splitAt (redResults reds) $ map distResTag res
          pure $
            insertRegulars red_tags elems' $
              insertIrregulars ws ws_flags ws_offsets (zip map_tags mapout_names) env
      | Just map_lam <- isMapSOAC form -> do
          (ws_flags, ws_offsets, ws) <- transformInnerMap segments env inps pat w arrs map_lam
          pure $ insertIrregulars ws ws_flags ws_offsets (zip (map distResTag res) $ patNames pat) env
    _ -> error $ "Unhandled Stm:\n" ++ prettyString stm

distResCerts :: DistEnv -> [DistInput] -> Certs
distResCerts env = Certs . map f
  where
    f (DistInputFree v _) = v
    f (DistInput rt _) = case resVar rt env of
      Regular v -> v
      Irregular {} -> error "resCerts: irregular"

transformDistributed ::
  M.Map ResTag IrregularRep ->
  Segments ->
  Distributed ->
  Builder GPU ()
transformDistributed irregs segments (Distributed dstms resmap) = do
  env <- foldM (transformDistStm segments) env_initial dstms
  forM_ (M.toList resmap) $ \(rt, (cs_inps, v, v_t)) ->
    certifying (distResCerts env cs_inps) $
      case resVar rt env of
        Regular v' -> letBindNames [v] $ BasicOp $ SubExp $ Var v'
        Irregular irreg -> do
          -- It might have an irregular representation, but we know
          -- that it is actually regular because it is a result.
          let shape = segmentsShape segments <> arrayShape v_t
          letBindNames [v] $
            BasicOp (Reshape ReshapeArbitrary shape (irregularElems irreg))
  where
    env_initial = DistEnv {distResMap = M.map Irregular irregs}

transformStm :: Scope SOACS -> Stm SOACS -> PassM (Stms GPU)
transformStm scope (Let pat _ (Op (Screma w arrs form)))
  | Just lam <- isMapSOAC form = do
      let arrs' =
            zipWith MapArray arrs $
              map paramType (lambdaParams (scremaLambda form))
          (distributed, _) = distributeMap scope pat w arrs' lam
          m = transformDistributed mempty (NE.singleton w) distributed
      traceM $ prettyString distributed
      runReaderT (runBuilder_ m) scope
transformStm _ stm = pure $ oneStm $ soacsStmToGPU stm

transformStms :: Scope SOACS -> Stms SOACS -> PassM (Stms GPU)
transformStms scope stms =
  fold <$> traverse (transformStm (scope <> scopeOf stms)) stms

transformFunDef :: Scope SOACS -> FunDef SOACS -> PassM (FunDef GPU)
transformFunDef consts_scope fd = do
  let FunDef
        { funDefBody = Body () stms res,
          funDefParams = fparams,
          funDefRetType = rettype
        } = fd
  stms' <- transformStms (consts_scope <> scopeOfFParams fparams) stms
  pure $
    fd
      { funDefBody = Body () stms' res,
        funDefRetType = rettype,
        funDefParams = fparams
      }

transformProg :: Prog SOACS -> PassM (Prog GPU)
transformProg prog = do
  consts' <- transformStms mempty $ progConsts prog
  funs' <- mapM (transformFunDef $ scopeOf (progConsts prog)) $ progFuns prog
  pure $ prog {progConsts = consts', progFuns = flatteningBuiltins <> funs'}

-- | Transform a SOACS program to a GPU program, using flattening.
flattenSOACs :: Pass SOACS GPU
flattenSOACs =
  Pass
    { passName = "flatten",
      passDescription = "Perform full flattening",
      passFunction = transformProg
    }
{-# NOINLINE flattenSOACs #-}
