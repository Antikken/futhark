module Futhark.Optimise.TileLoops.Shared
  ( TileM,
    Env,
    ceilDiv,
    indices,
    scratch,
    index,
    index_,
    update,
    forLoop,
    forLoop_,
    forLoopNest,
    forLoopNest_,
    segMap1D,
    segMap2D,
    segMapND,
    segMapND_,
    segScatter2D,
    VarianceTable,
    varianceInStms,
    isTileableRedomap,
    changeEnv,
    TileKind (..),
    myDebug,
    myDebugM,
    debugType,
  )
where

import Control.Monad
import Control.Monad.Reader
import Control.Monad.State
import Data.List (foldl', zip4)
import Data.Map qualified as M
import Debug.Trace
import Futhark.IR.GPU
import Futhark.IR.Mem.LMAD qualified as LMAD
import Futhark.IR.SeqMem qualified as ExpMem
import Futhark.MonadFreshNames
import Futhark.Tools
import Futhark.Transform.Rename

debugType :: (Monad m, HasScope rep m) => [Char] -> VName -> m ()
debugType s v =
  lookupType v >>= myDebugM . ((s ++ ":\n") ++) . (++ "\n") . prettyString

myDebug :: String -> a -> a
myDebug s = trace $ concat [sep, "\n", s', "\n", sep]
  where
    s' = s
    sep = replicate 100 '='

myDebugM :: Applicative f => String -> f ()
myDebugM s = myDebug s $ pure ()

type TileM = ReaderT (Scope GPU) (State VNameSource)

-- | Are we working with full or partial tiles?
data TileKind = TilePartial | TileFull

-- | List of valid indices into a given list.
indices :: [a] -> [Int]
indices = map fst . zip [0..]

-- | Ceiled integer division expression
ceilDiv :: (MonadBuilder m) => SubExp -> SubExp -> m (Exp (Rep m))
ceilDiv x y = pure $ BasicOp $ BinOp (SDivUp Int64 Unsafe) x y

-- | Scratch memory of a given shape.
scratch :: (MonadBuilder m) => String -> PrimType -> [SubExp] -> m VName
scratch se_name t shape = letExp se_name $ BasicOp $ Scratch t shape

-- | Index an array with the given outer_indices; any inner dims of arr
-- not indexed by outer_indices are sliced entirely.
index :: (MonadBuilder m) => String -> VName -> [VName] -> m VName
index se_desc arr = index_ se_desc arr . map Var

-- | Like index, but with indices given as SubExps.
index_ :: (MonadBuilder m) => String -> VName -> [SubExp] -> m VName
index_ se_desc arr outer_indices = do
  arr_t <- lookupType arr
  let slice = fullSlice arr_t $ map DimFix outer_indices
  letExp se_desc $ BasicOp $ Index arr slice

update :: (MonadBuilder m) => String -> VName -> [VName] -> SubExp -> m VName
update se_desc arr idxs new_elem =
  letExp se_desc $ BasicOp $ Update Unsafe arr (Slice $ map (DimFix . Var) idxs) new_elem

-- | Build a single for loop given a loop bound, loop merge initializers, and
-- the loop body.
forLoop ::
  SubExp -> -- loop bound.
  [VName] -> -- loop merge initializers.
  ( VName -> -- loop count variable.
    [VName] -> -- merge variables.
    Builder GPU [VName] -- merge update values.
  ) ->
  Builder GPU [VName]
forLoop i_bound merge body = do
  i <- newVName "i" -- could give this as arg to the function
  let loop_form = ForLoop i Int64 i_bound

  loop_inits <-
    mapM
      (\m -> lookupType m >>= newParam (baseString m ++ "_merge") . flip toDecl Unique)
      merge

  loop_body <-
    runBodyBuilder . localScope (scopeOfLoopForm loop_form <> scopeOfFParams loop_inits) $
      body i (map paramName loop_inits)
        >>= resultBodyM . map Var

  letTupExp "loop" $
    Loop (zip loop_inits $ map Var merge) loop_form loop_body

-- | Like forLoop, but with just one merge variable.
forLoop_ ::
  SubExp ->
  VName ->
  ( VName ->
    VName ->
    Builder GPU VName
  ) ->
  Builder GPU VName
forLoop_ bound merge body =
  fmap head $
    forLoop bound [merge] $
      \bound' [merge'] -> (: []) <$> body bound' merge'

-- | Build a perfect loop nest given a list of loop bounds, merge initializers,
-- and a loop body.
forLoopNest ::
  [SubExp] -> -- loop bound for each loop in the nest.
  [VName] -> -- loop merge initializers.
  ( [VName] -> -- loop variables ->
    [VName] -> -- merge variables ->
    Builder GPU [VName] -- merge update values.
  ) ->
  Builder GPU [VName]
forLoopNest = buildNest []
  where
    -- Recursively build nest; finally pass accumulated loop vars to loop body.
    buildNest is (bound : bounds) merge_inits body =
      forLoop bound merge_inits $
        \i merge -> buildNest (i : is) bounds merge body
    buildNest is _ merge body = body (reverse is) merge

-- | Like forLoopNest, but with just one merge variable.
forLoopNest_ ::
  [SubExp] ->
  VName ->
  ( [VName] ->
    VName ->
    Builder GPU VName
  ) ->
  Builder GPU VName
forLoopNest_ bounds merge_init body =
  fmap head $
    forLoopNest bounds [merge_init] $
      \bounds' [merge_init'] -> (: []) <$> body bounds' merge_init'

segMapND ::
  String -> -- desc
  SegLevel -> -- lvl
  ResultManifest -> -- manifest
  [SubExp] -> -- dims
  ( [VName] -> -- f
    Builder GPU Result
  ) ->
  Builder GPU [VName]
segMapND desc lvl manifest dims f = do
  let n_dims = length dims
  ltids <-
    mapM (newVName . ("ltid_dim_" ++)) $
      if n_dims <= 3
        then reverse $ take n_dims ["x", "y", "z"]
        else map show $ indices dims

  ltid_flat <- newVName "ltid_flat"
  let segspace = SegSpace ltid_flat $ zip ltids dims

  ((ts, res), stms) <- localScope (scopeOfSegSpace segspace) . runBuilder $ do
    res <- f ltids
    ts <- mapM subExpResType res
    pure (ts, res)

  let ret (SubExpRes cs se) = Returns manifest cs se
  letTupExp desc <=< renameExp $
    Op . SegOp $
      SegMap lvl segspace ts $
        KernelBody () stms $
          map ret res

segMapND_ ::
  String ->
  SegLevel ->
  ResultManifest ->
  [SubExp] ->
  ( [VName] ->
    Builder GPU Result
  ) ->
  Builder GPU VName
segMapND_ desc lvl manifest dims f =
  head <$> segMapND desc lvl manifest dims f

segMap1D ::
  String ->
  SegLevel ->
  ResultManifest ->
  SubExp -> -- dim_x
  (VName -> Builder GPU Result) ->
  Builder GPU [VName]
segMap1D desc lvl manifest dim_x f =
  segMapND desc lvl manifest [dim_x] (f . head)

segMap2D ::
  String ->
  SegLevel ->
  ResultManifest ->
  (SubExp, SubExp) -> -- (dim_x, dim_y)
  ( (VName, VName) ->
    Builder GPU Result
  ) ->
  Builder GPU [VName]
segMap2D desc lvl manifest (dim_y, dim_x) f =
  segMapND desc lvl manifest [dim_y, dim_x] (\(y : x : _) -> f (y, x))

segScatter2D ::
  String ->
  VName ->
  [SubExp] -> -- dims of sequential loop on top
  (SubExp, SubExp) -> -- (dim_y, dim_x)
  ([VName] -> (VName, VName) -> Builder GPU (SubExp, SubExp)) -> -- f
  Builder GPU VName
segScatter2D desc updt_arr seq_dims (dim_x, dim_y) f = do
  ltid_flat <- newVName "ltid_flat"
  ltid_y <- newVName "ltid_y"
  ltid_x <- newVName "ltid_x"

  seq_is <- replicateM (length seq_dims) (newVName "ltid_seq")
  let seq_space = zip seq_is seq_dims

  let segspace = SegSpace ltid_flat $ seq_space ++ [(ltid_y, dim_y), (ltid_x, dim_x)]
      lvl =
        SegThreadInBlock
          (SegNoVirtFull (SegSeqDims [0 .. length seq_dims - 1]))

  ((res_v, res_i), stms) <-
    runBuilder . localScope (scopeOfSegSpace segspace) $
      f seq_is (ltid_y, ltid_x)

  let ret = WriteReturns mempty updt_arr [(Slice [DimFix res_i], res_v)]
  let body = KernelBody () stms [ret]

  updt_arr_t <- lookupType updt_arr
  letExp desc <=< renameExp $ Op $ SegOp $ SegMap lvl segspace [updt_arr_t] body

-- | The variance table keeps a mapping from a variable name
-- (something produced by a 'Stm') to the kernel thread indices
-- that name depends on.  If a variable is not present in this table,
-- that means it is bound outside the kernel (and so can be considered
-- invariant to all dimensions).
type VarianceTable = M.Map VName Names

isTileableRedomap ::
  Stm GPU ->
  Maybe
    ( SubExp,
      [VName],
      (Commutativity, Lambda GPU, [SubExp], Lambda GPU)
    )
isTileableRedomap stm
  | Op (OtherOp (Screma w arrs form)) <- stmExp stm,
    Just (reds, map_lam) <- isRedomapSOAC form,
    Reduce red_comm red_lam red_nes <- singleReduce reds,
    all (primType . rowType . paramType) $ lambdaParams red_lam,
    all (primType . rowType . paramType) $ lambdaParams map_lam,
    lambdaReturnType map_lam == lambdaReturnType red_lam, -- No mapout arrays.
    not (null arrs),
    all primType $ lambdaReturnType map_lam,
    all (primType . paramType) $ lambdaParams map_lam =
      Just (w, arrs, (red_comm, red_lam, red_nes, map_lam))
  | otherwise =
      Nothing

defVarianceInStm :: VarianceTable -> Stm GPU -> VarianceTable
defVarianceInStm variance stm =
  foldl' add variance $ patNames $ stmPat stm
  where
    add variance' v = M.insert v binding_variance variance'
    look variance' v = oneName v <> M.findWithDefault mempty v variance'
    binding_variance = mconcat $ map (look variance) $ namesToList (freeIn stm)

-- just in case you need the Screma being treated differently than
-- by default; previously Cosmin had to enhance it when dealing with stream.
varianceInStm :: VarianceTable -> Stm GPU -> VarianceTable
varianceInStm v0 stm@(Let _ _ (Op (OtherOp Screma {})))
  | Just (_, arrs, (_, red_lam, red_nes, map_lam)) <- isTileableRedomap stm =
      let v = defVarianceInStm v0 stm
          red_ps = lambdaParams red_lam
          map_ps = lambdaParams map_lam
          card_red = length red_nes
          (acc_lam_f, arr_lam_f) = splitAt (card_red `quot` 2) red_ps
          stm_lam = bodyStms (lambdaBody map_lam) <> bodyStms (lambdaBody red_lam)

          f vacc (v_a, v_fm, v_fr_acc, v_fr_var) =
            let vrc = oneName v_a <> M.findWithDefault mempty v_a vacc
                vacc' = M.insert v_fm vrc vacc
                vrc' = oneName v_fm <> vrc
             in M.insert v_fr_acc (oneName v_fr_var <> vrc') $ M.insert v_fr_var vrc' vacc'

          v' =
            foldl' f v $
              zip4 arrs (map paramName map_ps) (map paramName acc_lam_f) (map paramName arr_lam_f)
       in varianceInStms v' stm_lam
varianceInStm v0 stm = defVarianceInStm v0 stm

varianceInStms :: VarianceTable -> Stms GPU -> VarianceTable
varianceInStms = foldl' varianceInStm

----------------
---- Helpers for building the environment that binds array variable names to their index functions
----------------

type LMAD = LMAD.LMAD (TPrimExp Int64 VName)

-- | Map from array variable names to their corresponding index functions.
--   The info is not guaranteed to be exact, e.g., we assume ifs and loops
--   return arrays layed out in normalized (row-major) form in memory.
--   We only record aliasing statements, such as transposition, slice, etc.
type IxFnEnv = M.Map VName LMAD

type WithEnv = M.Map VName (Lambda GPU, [SubExp])

type Env = (WithEnv, IxFnEnv)

changeEnv :: Env -> VName -> Exp GPU -> TileM Env
changeEnv (with_env, ixfn_env) y e = do
  with_env' <- changeWithEnv with_env e
  ixfn_env' <- changeIxFnEnv ixfn_env y e
  pure (with_env', ixfn_env')

changeWithEnv :: WithEnv -> Exp GPU -> TileM WithEnv
changeWithEnv with_env (WithAcc accum_decs inner_lam) = do
  let bindings = map mapfun accum_decs
      par_tps = take (length bindings) $ map paramName $ lambdaParams inner_lam
      with_env' = M.union with_env $ M.fromList $ zip par_tps bindings
  pure with_env'
  where
    mapfun (_, _, Nothing) = error "What the hack is an accumulator without operator?"
    mapfun (shp, _, Just (lam_inds, ne)) =
      let len_inds = length $ shapeDims shp
          lam_op = lam_inds {lambdaParams = drop len_inds $ lambdaParams lam_inds}
       in (lam_op, ne)
changeWithEnv with_env _ = pure with_env

composeIxfuns :: IxFnEnv -> VName -> VName -> (LMAD -> Maybe LMAD) -> TileM IxFnEnv
composeIxfuns env y x ixf_fun =
  case ixf_fun =<< M.lookup x env of
    Just ixf -> pure $ M.insert y ixf env
    Nothing -> do
      tp <- lookupType x
      pure $ case tp of
        Array _ptp shp _u
          | Just ixf <- ixf_fun $ LMAD.iota 0 $ map ExpMem.pe64 (shapeDims shp) ->
              M.insert y ixf env
        _ -> env

changeIxFnEnv :: IxFnEnv -> VName -> Exp GPU -> TileM IxFnEnv
changeIxFnEnv env y (BasicOp (Reshape ReshapeArbitrary shp_chg x)) =
  composeIxfuns env y x (`LMAD.reshape` fmap ExpMem.pe64 (shapeDims shp_chg))
changeIxFnEnv env y (BasicOp (Reshape ReshapeCoerce shp_chg x)) =
  composeIxfuns env y x (Just . (`LMAD.coerce` fmap ExpMem.pe64 (shapeDims shp_chg)))
changeIxFnEnv env y (BasicOp (Manifest perm x)) = do
  tp <- lookupType x
  case tp of
    Array _ptp shp _u -> do
      let shp' = map ExpMem.pe64 (shapeDims shp)
      let ixfn = LMAD.permute (LMAD.iota 0 shp') perm
      pure $ M.insert y ixfn env
    _ -> error "In TileLoops/Shared.hs, changeIxFnEnv: manifest applied to a non-array!"
changeIxFnEnv env y (BasicOp (Rearrange perm x)) =
  composeIxfuns env y x (Just . (`LMAD.permute` perm))
changeIxFnEnv env y (BasicOp (Index x slc)) =
  composeIxfuns env y x (Just . (`LMAD.slice` Slice (map (fmap ExpMem.pe64) $ unSlice slc)))
changeIxFnEnv env y (BasicOp (Opaque _ (Var x))) =
  composeIxfuns env y x Just
changeIxFnEnv env _ _ = pure env
