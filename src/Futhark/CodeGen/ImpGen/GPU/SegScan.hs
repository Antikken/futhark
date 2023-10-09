-- | Code generation for 'SegScan'.  Dispatches to either a
-- single-pass or two-pass implementation, depending on the nature of
-- the scan and the chosen abckend.
module Futhark.CodeGen.ImpGen.GPU.SegScan (compileSegScan) where

import Control.Monad
import Data.Maybe
import Futhark.CodeGen.ImpCode.GPU qualified as Imp
import Futhark.CodeGen.ImpGen hiding (compileProg)
import Futhark.CodeGen.ImpGen.GPU.Base
import Futhark.CodeGen.ImpGen.GPU.SegScan.SinglePass qualified as SinglePass
import Futhark.CodeGen.ImpGen.GPU.SegScan.TwoPass qualified as TwoPass
import Futhark.IR.GPUMem

-- The single-pass scan does not support multiple operators, so jam
-- them together here.
combineScanOps :: [SegBinOp GPUMem] -> SegBinOp GPUMem
combineScanOps scan_ops =
  SegBinOp
    { segBinOpComm = mconcat (map segBinOpComm scan_ops),
      segBinOpLambda = lam',
      segBinOpNeutral = concatMap segBinOpNeutral scan_ops,
      segBinOpShape = mempty -- Assumed
    }
  where
    lams = map segBinOpLambda scan_ops
    xParams lam = take (length (lambdaReturnType lam)) (lambdaParams lam)
    yParams lam = drop (length (lambdaReturnType lam)) (lambdaParams lam)
    lam' =
      Lambda
        { lambdaParams = concatMap xParams lams ++ concatMap yParams lams,
          lambdaReturnType = concatMap lambdaReturnType lams,
          lambdaBody =
            Body
              ()
              (mconcat (map (bodyStms . lambdaBody) lams))
              (concatMap (bodyResult . lambdaBody) lams)
        }

bodyHas :: (Exp GPUMem -> Bool) -> Body GPUMem -> Bool
bodyHas f = any (f' . stmExp) . bodyStms
  where
    f' e
      | f e = True
      | otherwise = isNothing $ walkExpM walker e
    walker =
      identityWalker
        { walkOnBody = const $ guard . not . bodyHas f
        }

canBeSinglePass :: [SegBinOp GPUMem] -> KernelBody GPUMem -> Maybe (SegBinOp GPUMem)
canBeSinglePass scan_ops map_kbody
  | all ok scan_ops,
    not $ bodyHas freshArray (Body () (kernelBodyStms map_kbody) []) =
      Just $ combineScanOps scan_ops
  | otherwise =
      Nothing
  where
    ok op =
      segBinOpShape op == mempty
        && all primType (lambdaReturnType (segBinOpLambda op))
        && not (bodyHas isAssert (lambdaBody (segBinOpLambda op)))
    isAssert (BasicOp Assert {}) = True
    isAssert _ = False
    -- XXX: Currently single pass scans cannot handle construction of
    -- arrays in the kernel body (#2013), because of insufficient
    -- memory expansion.  This can in principle be fixed.
    freshArray (BasicOp Manifest {}) = True
    freshArray (BasicOp Iota {}) = True
    freshArray (BasicOp Replicate {}) = True
    freshArray (BasicOp Scratch {}) = True
    freshArray (BasicOp Concat {}) = True
    freshArray (BasicOp ArrayLit {}) = True
    freshArray _ = False

-- | Compile 'SegScan' instance to host-level code with calls to
-- various kernels.
compileSegScan ::
  Pat LetDecMem ->
  SegLevel ->
  SegSpace ->
  [SegBinOp GPUMem] ->
  KernelBody GPUMem ->
  CallKernelGen ()
compileSegScan pat lvl space scan_ops kbody =
  sWhen (0 .<. n) $ do
    emit $ Imp.DebugPrint "\n# SegScan" Nothing
    target <- hostTarget <$> askEnv

    case (targetSupportsSinglePass target, canBeSinglePass scan_ops kbody) of
      (True, Just scan_ops') -> SinglePass.compileSegScan pat lvl space scan_ops' map_kbody
      _ -> TwoPass.compileSegScan pat lvl space scan_ops map_kbody

    emit $ Imp.DebugPrint "" Nothing
  where
    n = product $ map pe64 $ segSpaceDims space
    targetSupportsSinglePass CUDA = True
    targetSupportsSinglePass HIP  = True
    targetSupportsSinglePass _    = False
