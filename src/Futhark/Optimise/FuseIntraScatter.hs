{-# LANGUAGE TypeFamilies #-}

-- | Tries to fuse a scatter-like kernel with an intra-block
--     kernel that has produced the indices and values of 
--     the scatter.
module Futhark.Optimise.FuseIntraScatter (fuseIntraScatter) where

-- import Control.Monad
import Control.Monad.Reader
import Control.Monad.State
-- import Data.List qualified as L
import Data.Map.Strict qualified as M
-- import Data.Maybe
import Data.Sequence (Seq (..))
import Futhark.Builder
import Futhark.IR.GPU
-- import Futhark.Optimise.TileLoops.Shared
import Futhark.Pass
-- import Futhark.IR.Aliases
import Futhark.Analysis.Alias qualified as AnlAls
import Futhark.Analysis.LastUse
-- import Futhark.Tools
-- import Futhark.Transform.Rename
-- import Futhark.Pass (Pass (..))
import Futhark.Pass qualified as Pass
-- import Futhark.Util
import Futhark.Optimise.FuseIntraScatter.DataStructs
import Futhark.Optimise.FuseIntraScatter.FuseInstance
import Debug.Trace

-- | The pass definition.
fuseIntraScatter :: Pass GPU GPU
fuseIntraScatter =
  Pass "Intragroup-Scatter Fusion" 
       "Aims to fuse a scatter kernel with the intragroup kernel producing its indices and values" $
       \ prog -> do
         let prog_w_alises = AnlAls.aliasAnalysis prog
             (_, lu_tab_fns) = lastUseGPUNoMem prog_w_alises
             -- lu_tab_fns_lst = map (M.toList) (M.elems lu_tab_fns)
             scope_cts = scopeOf (progConsts prog)
         Pass.intraproceduralTransformationWithConsts pure (onFun scope_cts lu_tab_fns) prog
  where
    onFun scope_cts lu_tab_funs _ fd = do
      let lu_tab = lu_tab_funs M.! funDefName fd
          scope0 = scope_cts <> scopeOfFParams (funDefParams fd)
      body' <- trace ("\n Cosmin Scope0: "++show scope0 ++ "\n") $
                onBdy scope0 lu_tab $ funDefBody fd
      pure $ fd { funDefBody = body' }
    onBdy scope0 lu_tab body = do
      let td_env = FISEnv mempty lu_tab
          bu_env = BottomUpEnv lu_tab mempty mempty
      modifyNameSource $
          runState $
            runReaderT (fuseIScatBdy (td_env, bu_env) body) scope0
{--
      (_, stms) <- 
        modifyNameSource $
          runState $
            runReaderT (fuseIScatStms (td_env, bu_env) (bodyStms body)) scope0
      pure $ body { bodyStms = stms }
--}

updateTDEnv :: FISEnv -> Stm GPU -> FISEnv
updateTDEnv td_env _ = td_env

fuseIScatStms :: (FISEnv, BottomUpEnv GPU) -> Stms GPU -> FuseIScatM ( (FISEnv, BottomUpEnv GPU), Stms GPU )
fuseIScatStms env Empty = 
  pure (env, Empty)
fuseIScatStms (td_env, bu_env) (stm :<| stms) = do
  scope0 <- askScope
  let scope = scope0 <> scopeOf stms
  -- We build the top-down env in a top-down manner, of course
      td_env' = updateTDEnv td_env stm
  -- But our analysis advances bottom-up
  localScope scope $ do
    (env', stms') <- fuseIScatStms (td_env', bu_env) stms
    (env'', cur_stms') <- fuseIScatStm env' stm
    pure (env'', cur_stms' <>  stms')

fuseIScatBdy :: (FISEnv, BottomUpEnv GPU) -> Body GPU -> FuseIScatM (Body GPU)
fuseIScatBdy env@(td_env, _) bdy = do
  scope0 <- askScope
  bdy' <- localScope (scope0 <> scopeOf (bodyStms bdy)) $ do
            fuseInCurrentBody td_env bdy
  (_, stms') <- fuseIScatStms env (bodyStms bdy')
  return $ Body (bodyDec bdy') stms' (bodyResult bdy')


{--
fuseIScatBdy :: (TopDownEnv, BottomUpEnv GPU) -> Body GPU -> FuseIScatM (Body GPU)
fuseIScatBdy env (Body () stms res) = do
  (_, stms') <- fuseIScatStms env stms
  return $ Body () stms' res
--}

fuseIScatStm :: (FISEnv, BottomUpEnv GPU) -> Stm GPU -> FuseIScatM ( (FISEnv, BottomUpEnv GPU), Stms GPU )
fuseIScatStm env (Let pat aux e) = do
  -- env' <- changeEnv env (head $ patNames pat) e
  e' <- mapExpM (optimise env) e
  pure (env, oneStm $ Let pat aux e')
  where
    optimise env' = identityMapper {mapOnBody = \scope -> localScope scope . fuseIScatBdy env'}


fuseInCurrentBody :: FISEnv -> Body GPU -> FuseIScatM (Body GPU)
fuseInCurrentBody td_env (Body aux stms res) = do
  let scatters = filter isScatter (stmsToList stms)
  m_res <- tryRec scatters
  case m_res of
    Nothing -> return $ Body aux stms res
      -- ^ no fusion was possible; recurse in each statement
    Just (stms_before, stms_new, stms_after) -> do
      -- ^ we performed a fusion: update statements
        let new_stms = stms_before <> stms_new <> stms_after
        fuseInCurrentBody td_env (Body aux new_stms res)
  where
    tryRec :: [Stm GPU] -> FuseIScatM (Maybe (Stms GPU, Stms GPU, Stms GPU))
    tryRec [] = return Nothing
    tryRec (scat_stm:scat_stms) = do
      m_res <- fuseInstance td_env stms scat_stm
      case m_res of
        Nothing -> tryRec scat_stms
        Just inst_res-> return $ Just inst_res
    isScatter (Let _pat _aux (Op (SegOp old_kernel)))
      | SegMap SegThread {} _space _kertp (KernelBody () _kstms kres) <- old_kernel =
          all isScatterRes kres
        where
          isScatterRes (WriteReturns _ _ _) = True
          isScatterRes _ = False
    isScatter _ = False
        

{--
fuseIScatBdyNew :: (TopDownEnv, BottomUpEnv GPU) -> Body GPU -> FuseIScatM (Body GPU)
fuseIScatBdyNew env (Body () stms res) = do
  let scatters = filterStms isScatter stms
  res <- tryRec stms scatters
  let stms' =
    case res of
      Nothing -> stms
      -- ^ no fusion was possible; recurse in each statement
      Just (stms_before, orig_intra, stms_interm, orig_scatter, stms_after, fused_intra) ->
      -- ^ we performed a fusion: update statements
        let new_stms = stms_before <> oneStm fused_intra <> stms_interm <> stms_after
            Body _ stms' _ <- fuseIScatBdyNew env (Body () new_stms res)
        
     
  (_, stms') <- fuseIScatStms env stms
  return $ Body () stms' res
--}

{-- 
seqStm (Let pat aux (Match scrutinee cases def dec)) = do
  cases' <- forM cases seqCase
  let (Body ddec dstms dres) = def
  dstms' <- collectSeqBuilder' $ forM (stmsToList dstms) seqStm
  (dres', stms') <-
    collectSeqBuilder $
      localScope (scopeOf dstms') $
        fixReturnTypes pat dres
  let def' = Body ddec (dstms' <> stms') dres'
  lift $ do addStm $ Let pat aux (Match scrutinee cases' def' dec)
  where
    seqCase :: Case (Body GPU) -> SeqBuilder (Case (Body GPU))
    seqCase (Case cpat body) = do
      let (Body bdec bstms bres) = body
      bstms' <-
        collectSeqBuilder' $
          forM (stmsToList bstms) seqStm
      (bres', stms') <-
        collectSeqBuilder $
          localScope (scopeOf bstms') $
            fixReturnTypes pat bres
      let body' = Body bdec (bstms' <> stms') bres'
      pure $ Case cpat body'
seqStm (Let pat aux (Loop header form body)) = do
  let fparams = L.map fst header
  let (Body bdec bstms bres) = body
  bstms' <-
    collectSeqBuilder' $
      localScope (scopeOfFParams fparams) $
        forM_ (stmsToList bstms) seqStm
  (bres', stms') <-
    collectSeqBuilder $
      localScope (scopeOf bstms') $
        fixReturnTypes pat bres
  let body' = Body bdec (bstms' <> stms') bres'
  lift $ do addStm $ Let pat aux (Loop header form body')
--}
