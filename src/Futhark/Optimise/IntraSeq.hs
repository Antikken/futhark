{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}
{-# HLINT ignore "Use zipWith" #-}
{-# HLINT ignore "Use uncurry" #-}
{-# HLINT ignore "Use uncurry" #-}
{-# OPTIONS_GHC -Wno-name-shadowing #-}
module Futhark.Optimise.IntraSeq (intraSeq) where

import Language.Futhark.Core
import Futhark.Pass
import Futhark.IR.GPU
import Futhark.Builder.Class
import Futhark.Construct
import Futhark.Transform.Rename

import Control.Monad.Reader
import Control.Monad.State

import Data.Map as M
import Data.IntMap.Strict as IM
import Data.List as L

import Debug.Pretty.Simple
import Debug.Trace


type SeqM a = ReaderT (Scope GPU) (State VNameSource) a

runSeqM' :: SeqM a -> Scope GPU -> Builder GPU a
runSeqM' m sc = do
  let tmp = runReaderT m sc
  st <- get
  let tmp' = runState tmp st
  pure $ fst tmp'

runSeqM :: SeqM a -> Builder GPU a
runSeqM m = do
  scp <- askScope
  runSeqM' m scp

runSeqMExtendedScope :: SeqM a -> Scope GPU -> Builder GPU a
runSeqMExtendedScope m sc = do
  scp <- askScope
  runSeqM' m (sc <> scp)


-- | A structure for convenient passing of different information needed at 
-- various stages during the pass.
data Env = Env {
  grpId      :: SubExp,             -- The group id
  grpSize    :: SubExp,             -- The group size after seq
  grpsizeOld :: SubExp,             -- The group size before seq
  threadId   :: Maybe VName,        -- the thread id if available at given stage
  nameMap    :: M.Map VName VName,  -- Mapping from arrays to tiles
  seqFactor  :: SubExp
}

setMapping :: Env -> M.Map VName VName -> Env
setMapping (Env gid gSize gSizeOld tid _ factor) mapping =
            Env gid gSize gSizeOld tid mapping factor

updateMapping :: Env -> M.Map VName VName -> Env
updateMapping env mapping =
  let mapping' = mapping `M.union` nameMap env
  in setMapping env mapping'

lookupMapping :: Env -> VName -> Maybe VName
lookupMapping env name 
  | M.member name (nameMap env) = do
    case M.lookup name (nameMap env) of
      Just n -> 
        case lookupMapping env n of
          Nothing -> Just n
          n' -> n'
      Nothing -> Nothing
lookupMapping _ _ = Nothing

updateEnvTid :: Env -> VName -> Env
updateEnvTid (Env gid sz szo _ tm sq) tid = Env gid sz szo (Just tid) tm sq

getThreadId :: Env -> VName
getThreadId env =
  case threadId env of
    (Just tid ) -> tid
    _ -> error "No tid to get"

intraSeq :: Pass GPU GPU
intraSeq =
    Pass "name" "description" $
      intraproceduralTransformation onStms
    where
      onStms scope stms =
        modifyNameSource $
          runState $
            runReaderT (seqStms stms) scope




-- SeqStms is only to be used for top level statements. To sequentialize
-- statements within a body use seqStms'
seqStms ::
  Stms GPU ->
  SeqM (Stms GPU)
seqStms stms =
  foldM (\ss s -> do
      ss' <- runBuilder_ $ localScope (scopeOf ss) $ seqStm s
      pure $ ss <> ss'
      ) mempty (stmsToList stms)


-- | Matches against singular statements at the group level. That is statements
-- that are either SegOps at group level or intermediate statements between
-- such statements
seqStm ::
  Stm GPU ->
  Builder GPU ()
seqStm (Let pat aux (Op (SegOp (
            SegMap (SegGroup virt (Just grid)) space ts kbody)))) = do
  -- As we are at group level all arrays in scope must be global, i.e. not
  -- local to the current group. We simply create a tile for all such arrays
  -- and let a Simplify pass remove unused tiles.

  -- TODO: Somehow select what the seqFactor should be
  let e       = intConst Int64 4
  let grpId   = fst $ head $ unSegSpace space
  let sizeOld = unCount $ gridGroupSize grid
  sizeNew <- letSubExp "group_size" =<< eBinOp (SDivUp Int64 Unsafe)
                                            (eSubExp sizeOld)
                                            (eSubExp e)

  let env = Env (Var grpId) sizeNew sizeOld Nothing mempty e

  exp' <- buildSegMap' $ do
    -- Update the env with mappings
    env' <- mkTiles env

    -- Create the new grid with the new group size
    let grid' = Just $ KernelGrid (gridNumGroups grid) (Count sizeNew)
    kresults <- seqKernelBody env' kbody

    let lvl' = SegGroup virt grid'

    kresults' <- flattenResults pat kresults

    pure (kresults', lvl', space, ts)

  addStm $ Let pat aux exp'
  pure ()



-- Catch all pattern. This will mainly just tell us if we encounter some
-- statement in a test program so that we know that we will have to handle it
seqStm stm = error $
             "Encountered unhandled statement at group level: " ++ show stm


seqKernelBody ::
  Env ->
  KernelBody GPU ->
  Builder GPU [KernelResult]
seqKernelBody env (KernelBody _ stms results) = do
  seqStms' env stms
  pure results


-- | Much like seqStms but now carries an Env
seqStms' ::
  Env ->
  Stms GPU ->
  Builder GPU ()
seqStms' env stms = do
  (_, stms') <- collectStms $ mapM (seqStm' env) stms
  addStms stms'


-- |Expects to only match on statements at thread level. That is SegOps at
-- thread level or statements between such SegOps
seqStm' ::
  Env ->
  Stm GPU ->
  Builder GPU ()
seqStm' env (Let pat aux
            (Op (SegOp (SegRed lvl@(SegThread {}) space binops ts kbody)))) = do

  let tid = fst $ head $ unSegSpace space
  let env' = updateEnvTid env tid
  
  -- thread local reduction
  reds <- mapM (mkSegMapRed env' kbody ts) binops

  -- TODO: multiple binops
  kbody' <- mkResultKBody env' kbody $ head reds

  -- Update remaining types
  let numResConsumed = numArgsConsumedBySegop binops
  let space' = SegSpace (segFlat space) [(fst $ head $ unSegSpace space, grpSize env')]
  -- TODO: binop head
  tps <- mapM lookupType $ head reds
  let ts' = L.map (stripArray 1) tps
  let (patKeep, patUpdate) = L.splitAt numResConsumed $ patElems pat
  let pat' = Pat $ patKeep ++
        L.map (\(p, t) -> setPatElemDec p t) (zip patUpdate (L.drop numResConsumed tps))

  addStm $ Let pat' aux (Op (SegOp (SegRed lvl space' binops ts' kbody')))


seqStm' env (Let pat aux (Op (SegOp
          (SegMap lvl@(SegThread {}) space ts kbody)))) = do

  usedArrays <- getUsedArraysIn env kbody
  maps <- buildSegMapTup_ "map_intermediate" $ do
    tid <- newVName "tid"
    phys <- newVName "phys_tid"
    let env' = updateEnvTid env tid
    lambSOAC <- buildSOACLambda env' usedArrays kbody ts
    let screma = mapSOAC lambSOAC
    chunks <- mapM (letChunkExp (seqFactor env') tid) usedArrays
    res <- letTupExp' "res" $ Op $ OtherOp $
            Screma (seqFactor env) chunks screma
    let lvl' = SegThread SegNoVirt Nothing
    let space' = SegSpace phys [(tid, grpSize env)]
    let types' = scremaType (seqFactor env) screma
    let kres = L.map (Returns ResultMaySimplify  mempty) res
    pure (kres, lvl', space', types')

  let tid = fst $ head $ unSegSpace space
  let env' = updateEnvTid env tid
  kbody' <- mkResultKBody env' kbody maps

  let space' = SegSpace (segFlat space) [(fst $ head $ unSegSpace space, grpSize env')]
  tps <- mapM lookupType maps
  let ts' = L.map (stripArray 1) tps
  let pat' = Pat $ L.map (\(p, t) -> setPatElemDec p t) (zip (patElems pat) tps)
  addStm $ Let pat' aux (Op (SegOp (SegMap lvl space' ts' kbody')))


seqStm' env (Let pat aux
            (Op (SegOp (SegScan (SegThread {}) _ binops ts kbody)))) = do
  usedArrays <- getUsedArraysIn env kbody
  
  -- do local reduction
  reds <- mapM (mkSegMapRed env kbody ts) binops
  -- TODO: head until multiple binops
  let redshead = head reds
  let numResConsumed = numArgsConsumedBySegop binops
  let (scanReds, fusedReds) = L.splitAt numResConsumed redshead

  -- scan over reduction results
  imScan <- buildSegScan "scan_agg" $ do
    tid <- newVName "tid"
    let env' = updateEnvTid env tid
    phys <- newVName "phys_tid"
    binops' <- renameSegBinOp binops
    
    let lvl' = SegThread SegNoVirt Nothing
    let space' = SegSpace phys [(tid, grpSize env')]
    results <- mapM (buildKernelResult env') scanReds 
    let ts' = L.take numResConsumed ts
    pure (results, lvl', space', binops', ts')

  scans' <- buildSegMapTup_ "scan_res" $ do
    tid <- newVName "tid"
    phys <- newVName "phys_tid"

    -- TODO: Uses head
    let binop = head binops
    let neutral = segBinOpNeutral binop
    scanLambda <- renameLambda $ segBinOpLambda binop

    let scanNames = L.map getVName imScan

    idx <- letSubExp "idx" =<< eBinOp (Sub Int64 OverflowUndef)
                                    (eSubExp $ Var tid)
                                    (eSubExp $ intConst Int64 1)
    ne <- letTupExp' "ne" =<< eIf (eCmpOp (CmpEq $ IntType Int64)
                                  (eSubExp $ Var tid)
                                  (eSubExp $ intConst Int64 0)
                               )
                               (eBody $ L.map toExp neutral)
                               (eBody $ L.map (\s -> eIndex s (eSubExp idx)) scanNames)

    let env' = updateEnvTid env tid
    lambSOAC <- buildSOACLambda env' usedArrays kbody ts
    let scanSoac = scanomapSOAC [Scan scanLambda ne] lambSOAC
    es <- mapM (getChunk env tid (seqFactor env)) usedArrays
    res <- letTupExp' "res" $ Op $ OtherOp $ Screma (seqFactor env) es scanSoac
    let usedRes = L.map (Returns ResultMaySimplify mempty) $ L.take numResConsumed res
    fused <- mapM (buildKernelResult env') fusedReds

    let lvl' = SegThread SegNoVirt Nothing
    let space' = SegSpace phys [(tid, grpSize env)]
    let types' = scremaType (seqFactor env) scanSoac
    pure (usedRes ++ fused, lvl', space', types')

  forM_ (zip (patElems pat) scans') (\(p, s) ->
            let exp' = Reshape ReshapeArbitrary (Shape [grpsizeOld env]) s
            in addStm $ Let (Pat [p]) aux $ BasicOp exp')

-- Catch all
seqStm' _ stm = error $
                "Encountered unhandled statement at thread level: " ++ show stm

buildSOACLambda :: Env -> [VName] -> KernelBody GPU -> [Type] -> Builder GPU (Lambda GPU)
buildSOACLambda env usedArrs kbody retTs = do
  ts <- mapM lookupType usedArrs
  let ts' = L.map (Prim . elemType) ts
  params <- mapM (newParam "par" ) ts'
  let mapNms = L.map paramName params
  let env' = updateMapping env $ M.fromList $ zip usedArrs mapNms
  kbody' <- runSeqMExtendedScope (seqKernelBody' env' kbody) (scopeOfLParams params)
  let body = kbodyToBody kbody'
  renameLambda $
    Lambda
    { lambdaParams = params,
      lambdaBody = body,
      lambdaReturnType = retTs
    }

getVName :: SubExp -> VName
getVName (Var name) = name
getVName e = error $ "SubExp is not of type Var in getVName:\n" ++ show e

getTidIndexExp :: Env -> VName -> Builder GPU (Exp GPU)
getTidIndexExp env name = do
  tp <- lookupType name
  let outerDim = [DimFix $ Var $ getThreadId env]
  let index =
        case arrayRank tp of
          0 -> SubExp $ Var name
          1 -> Index name $ Slice outerDim
          2 -> Index name $ Slice $ 
                outerDim ++ [DimSlice (intConst Int64 0) (seqFactor env) (intConst Int64 1)]
          _ -> error "Arrays are not expected to have more than 2 dimensions \n"
  pure $ BasicOp index

buildKernelResult :: Env -> VName -> Builder GPU KernelResult
buildKernelResult env name = do
  i <- getTidIndexExp env name
  res <- letSubExp "res" i
  pure $ Returns ResultMaySimplify mempty res

mkResultKBody :: Env -> KernelBody GPU -> [VName] -> Builder GPU (KernelBody GPU)
mkResultKBody env (KernelBody dec _ _) names = do
  (res, stms) <- collectStms $ do mapM (buildKernelResult env) names
  pure $ KernelBody dec stms res



numArgsConsumedBySegop :: [SegBinOp GPU] -> Int
numArgsConsumedBySegop binops =
  let numResUsed = L.foldl
                    (\acc (SegBinOp _ (Lambda pars _ _) neuts _)
                      -> acc + length pars - length neuts) 0 binops
  in numResUsed

seqKernelBody' ::
  Env ->
  KernelBody GPU ->
  SeqM (KernelBody GPU)
seqKernelBody' env (KernelBody dec stms results) = do
  stms' <- seqStms'' env stms
  pure $ KernelBody dec stms' results

seqStms'' ::
  Env ->
  Stms GPU ->
  SeqM (Stms GPU)
seqStms'' env stms = do
  (stms', _) <- foldM (\(ss, env') s -> do
      (env'', ss') <- runBuilder $ localScope (scopeOf ss <> scopeOf s) $ seqStm'' env' s
      pure (ss <> ss', env'')
      ) (mempty, env) (stmsToList stms)
  pure stms'

seqStm'' ::
  Env ->
  Stm GPU ->
  Builder GPU Env
seqStm'' env stm@(Let pat aux (BasicOp (Index arr _))) =
  case lookupMapping env arr of 
    Just name -> do
      i <- getTidIndexExp env name
      addStm $ Let pat aux i
      pure env
    Nothing -> do 
      addStm stm
      pure env
seqStm'' env stm = do
  addStm stm
  pure env

mkSegMapRed ::
  Env ->
  KernelBody GPU ->
  [Type] ->                   -- segmap return types
  SegBinOp GPU ->
  Builder GPU [VName]
mkSegMapRed env kbody retTs binop = do
    let comm = segBinOpComm binop
    let ne   = segBinOpNeutral binop
    lambda <- renameLambda $ segBinOpLambda binop

    buildSegMapTup_ "red_intermediate" $ do
      tid <- newVName "tid"
      let env' = updateEnvTid env tid
      phys <- newVName "phys_tid"
      sz <- mkChunkSize tid env
      usedArrs <- getUsedArraysIn env kbody
      lambSOAC <- buildSOACLambda env' usedArrs kbody retTs
      let screma = redomapSOAC [Reduce comm lambda ne] lambSOAC
      chunks <- mapM (getChunk env tid sz) usedArrs

      -- create a scratch array that of size seqFactor that each chunk can be written into
      -- this is to ensure correct sizes in case the last thread does not handle seqFactor elements
      -- scratch arrays holding a chunk used in a reduction will be padded with the neutral element
      let scratchElems = ne ++ replicate (length usedArrs - length ne) (constant (0 :: Int64))
      chunksScratch <- mapM (letExp "chunk_scratch" . BasicOp .
                              Replicate (Shape [seqFactor env])) scratchElems
      chunks' <- mapM (\(scratch, chunk) ->
        letExp "chunk" $ BasicOp $ Update Unsafe scratch
          (Slice [DimSlice (intConst Int64 0) sz (intConst Int64 1)])
          $ Var chunk) $ L.zip chunksScratch chunks

      res <- letTupExp' "res" $ Op $ OtherOp $
                Screma (seqFactor env) chunks' screma

      let lvl' = SegThread SegNoVirt Nothing
      let space' = SegSpace phys [(tid, grpSize env)]
      let types' = scremaType (seqFactor env) screma
      let kres = L.map (Returns ResultMaySimplify mempty) res
      pure (kres, lvl', space', types')

getUsedArraysIn ::
  Env ->
  KernelBody GPU ->
  Builder GPU [VName]
getUsedArraysIn env kbody = do
  scope <- askScope
  let (arrays, _) = unzip $ M.toList $ M.filter isArray scope
  let free = IM.elems $ namesIntMap $ freeIn kbody
  let freeArrays = arrays `intersect` free
  let arrays' =
        L.map ( \ arr ->
          if M.member arr (nameMap env) then
            let (Just tile) = M.lookup arr (nameMap env)
            in tile
          else arr
          ) freeArrays
  pure arrays'


getChunk ::
  Env ->
  VName ->              -- thread Id
  SubExp ->             -- size of chunk
  VName ->              -- Array to get chunk from
  Builder GPU VName
getChunk env tid sz arr = do
  tp <- lookupType arr

  offset <- letSubExp "offset" =<< eBinOp (Mul Int64 OverflowUndef)
                                          (eSubExp $ seqFactor env)
                                          (eSubExp $ Var tid)

  let dims =
        case arrayRank tp of
          1 -> [DimSlice offset sz (intConst Int64 1)]
          2 -> [DimFix $ Var tid, DimSlice (intConst Int64 0) sz (intConst Int64 1)]
          _ -> error "unhandled dims in getChunk"

  letExp "chunk" $ BasicOp $ Index arr (Slice dims)


kbodyToBody :: KernelBody GPU -> Body GPU
kbodyToBody (KernelBody dec stms res) =
  let res' = L.map (subExpRes . kernelResultSubExp) res
  in Body
    { bodyDec = dec,
      bodyStms = stms,
      bodyResult = res'
    }


flattenResults ::
  Pat (LetDec GPU)->
  [KernelResult] ->
  Builder GPU [KernelResult]
flattenResults pat kresults = do
  subExps <- forM (zip kresults $ patTypes pat) $ \(res, tp)-> do
    let resSubExp = kernelResultSubExp res
    case resSubExp of
      (Constant _) -> letSubExp "const_res" $ BasicOp $ SubExp resSubExp
      (Var name) -> do
          resType <- lookupType name
          if arrayRank resType == 0 then
            letSubExp "scalar_res" $ BasicOp $ SubExp resSubExp
          else
            letSubExp "reshaped_res" $ BasicOp $ Reshape ReshapeArbitrary (arrayShape $ stripArray 1 tp) name

  let kresults' = L.map (Returns ResultMaySimplify mempty) subExps

  pure kresults'

renameSegBinOp :: [SegBinOp GPU] -> Builder GPU [SegBinOp GPU]
renameSegBinOp segbinops =
  forM segbinops $ \(SegBinOp comm lam ne shape) -> do
    lam' <- renameLambda lam
    pure $ SegBinOp comm lam' ne shape


letChunkExp :: SubExp -> VName -> VName -> Builder GPU VName
letChunkExp sz tid arrName = do
  letExp "chunk" $ BasicOp $
    Index arrName (Slice [DimFix (Var tid),
    DimSlice (intConst Int64 0) sz (intConst Int64 1)])


-- Generates statements that compute the pr. thread chunk size. This is needed
-- as the last thread in a block might not have seqFactor amount of elements
-- to read. 
mkChunkSize ::
  VName ->               -- The thread id
  Env ->
  Builder GPU SubExp     -- Returns the SubExp in which the size is
mkChunkSize tid env = do
  offset <- letSubExp "offset" $ BasicOp $
              BinOp (Mul Int64 OverflowUndef) (Var tid) (seqFactor env)
  tmp <- letSubExp "tmp" $ BasicOp $
              BinOp (Sub Int64 OverflowUndef) (grpsizeOld env) offset
  letSubExp "size" $ BasicOp $
              BinOp (SMin Int64) tmp (seqFactor env)


-- | Creates a tile for each array in scope at the time of caling it.
-- That is if called at the correct time it will create a tile for each
-- global array
mkTiles ::
  Env ->
  Builder GPU Env
mkTiles env = do
  scope <- askScope
  let arrsInScope = M.toList $  M.filter isArray scope

  scratchSize <- letSubExp "tile_size" =<< eBinOp (Mul Int64 OverflowUndef)
                                               (eSubExp $ seqFactor env)
                                               (eSubExp $ grpSize env)

  tiles <- forM arrsInScope $ \ (arrName, arrInfo) -> do
    let tp = elemType $ typeOf arrInfo

    -- Build SegMap that will write to tile
    tile <- buildSegMap_ "tile_staging" $ do
      tid <- newVName "tid"
      phys <- newVName "phys_tid"

      -- Allocate local scratch chunk
      chunk <- letExp "chunk_scratch" $ BasicOp $ Scratch tp [seqFactor env]

      -- Compute the chunk size of the current thread. Last thread might need to read less
      sliceSize <- mkChunkSize tid env
      let outerDim = ([DimFix $ grpId env | arrayRank (typeOf arrInfo) > 1])
      let sliceIdx = DimSlice (Var tid) sliceSize (grpSize env)
      slice <- letSubExp "slice" $ BasicOp $ Index arrName
                                  (Slice $ outerDim ++ [sliceIdx])

      -- Update the chunk
      chunk' <- letSubExp "chunk" $ BasicOp $ Update Unsafe chunk
                                    (Slice [DimSlice (intConst Int64 0) sliceSize (intConst Int64 1)]) slice

      let lvl = SegThread SegNoVirt Nothing
      let space = SegSpace phys [(tid, grpSize env)]
      let types = [Array tp (Shape [seqFactor env]) NoUniqueness]
      pure ([Returns ResultMaySimplify mempty chunk'], lvl, space, types)

    -- transpose and flatten
    tileT <- letExp "tileT" $ BasicOp $ Rearrange [1,0] tile
    tileFlat <- letExp "tile_flat" $ BasicOp $ Reshape
                ReshapeArbitrary (Shape [scratchSize]) tileT

    -- Now each thread will read their actual chunk
    tile' <- buildSegMap_ "tile" $ do
      tid <- newVName "tid"
      phys <- newVName "phys_tid"

      start <- letSubExp "start" =<< eBinOp (Mul Int64 OverflowUndef)
                                            (eSubExp $ Var tid)
                                            (eSubExp $ seqFactor env)
      -- NOTE: Can just use seqFactor here as we read from the padded tile craeted above
      let dimSlice = DimSlice start (seqFactor env) (intConst Int64 1)

      chunk <- letSubExp "chunk" $ BasicOp $ Index tileFlat
                                    (Slice [dimSlice])
      let lvl = SegThread SegNoVirt Nothing
      let space = SegSpace phys [(tid, grpSize env)]
      let types = [Array tp (Shape [seqFactor env]) NoUniqueness]
      pure ([Returns ResultPrivate mempty chunk], lvl, space, types)

    pure (arrName, tile')

  pure $ setMapping env (M.fromList tiles)

isArray :: NameInfo GPU -> Bool
isArray info = arrayRank (typeOf info) > 0

-- Builds a SegMap at thread level containing all bindings created in m
-- and returns the subExp which is the variable containing the result
buildSegMap ::
  String ->
  Builder GPU ([KernelResult], SegLevel, SegSpace, [Type]) ->
  Builder GPU SubExp
buildSegMap name m = do
  ((res, lvl, space, ts), stms) <- collectStms m
  let kbody = KernelBody () stms res
  letSubExp name $ Op $ SegOp $ SegMap lvl space ts kbody

-- Like buildSegMap but returns the VName instead of the actual 
-- SubExp. Just for convenience
buildSegMap_ ::
  String ->
  Builder GPU ([KernelResult], SegLevel, SegSpace, [Type]) ->
  Builder GPU VName
buildSegMap_ name m = do
  subExps <- buildSegMap name m
  pure $ varFromExp subExps
  where
    varFromExp :: SubExp -> VName
    varFromExp (Var nm) = nm
    varFromExp e = error $ "Expected SubExp of type Var, but got:\n" ++ show e

-- like buildSegMap but builds a tup exp
buildSegMapTup ::
  String ->
  Builder GPU ([KernelResult], SegLevel, SegSpace, [Type]) ->
  Builder GPU [SubExp]
buildSegMapTup name m = do
  ((res, lvl, space, ts), stms) <- collectStms m
  let kbody = KernelBody () stms res
  letTupExp' name $ Op $ SegOp $ SegMap lvl space ts kbody

-- Like buildSegMapTup but returns the VName instead of the actual 
-- SubExp. Just for convenience
buildSegMapTup_ ::
  String ->
  Builder GPU ([KernelResult], SegLevel, SegSpace, [Type]) ->
  Builder GPU [VName]
buildSegMapTup_ name m = do
  subExps <- buildSegMapTup name m
  pure $ L.map varFromExp subExps
  where
    varFromExp :: SubExp -> VName
    varFromExp (Var nm) = nm
    varFromExp e = error $ "Expected SubExp of type Var, but got:\n" ++ show e


buildSegMap' ::
  Builder GPU ([KernelResult], SegLevel, SegSpace, [Type]) ->
  Builder GPU (Exp GPU)
buildSegMap' m = do
  ((res, lvl, space, ts), stms) <- collectStms m
  let kbody' = KernelBody () stms res
  pure $ Op $ SegOp $ SegMap lvl space ts kbody'

-- | The [KernelResult] from the input monad is what is being passed to the 
-- segmented binops
buildSegScan ::
  String ->          -- SubExp name
  Builder GPU ([KernelResult], SegLevel, SegSpace, [SegBinOp GPU], [Type]) ->
  Builder GPU [SubExp]
buildSegScan name m = do
  ((results, lvl, space, bops, ts), stms) <- collectStms m
  let kbody = KernelBody () stms results
  letTupExp' name $ Op $ SegOp $ SegScan lvl space bops ts kbody

