{-# LANGUAGE FlexibleContexts #-}

-- | All (almost) compiler pipelines end with an 'Action', which does
-- something with the result of the pipeline.
module Futhark.Actions
  ( printAction,
    printAliasesAction,
    impCodeGenAction,
    kernelImpCodeGenAction,
    multicoreImpCodeGenAction,
    metricsAction,
    compileCAction,
    compileCtoWASMAction,
    compileOpenCLAction,
    compileCUDAAction,
    compileMulticoreAction,
  )
where

import Control.Monad
import Control.Monad.IO.Class
import Data.Maybe (fromMaybe)
import Futhark.Analysis.Alias
import Futhark.Analysis.Metrics
import qualified Futhark.CodeGen.Backends.CCUDA as CCUDA
import qualified Futhark.CodeGen.Backends.COpenCL as COpenCL
import qualified Futhark.CodeGen.Backends.MulticoreC as MulticoreC
import qualified Futhark.CodeGen.Backends.SequentialC as SequentialC
import qualified Futhark.CodeGen.ImpGen.Kernels as ImpGenKernels
import qualified Futhark.CodeGen.ImpGen.Multicore as ImpGenMulticore
import qualified Futhark.CodeGen.ImpGen.Sequential as ImpGenSequential
import Futhark.Compiler.CLI
import Futhark.IR
import Futhark.IR.KernelsMem (KernelsMem)
import Futhark.IR.MCMem (MCMem)
import Futhark.IR.Prop.Aliases
import Futhark.IR.SeqMem (SeqMem)
import Futhark.Util (runProgramWithExitCode, unixEnvironment)
import System.Exit
import System.FilePath
import qualified System.Info

-- | Print the result to stdout.
printAction :: ASTLore lore => Action lore
printAction =
  Action
    { actionName = "Prettyprint",
      actionDescription = "Prettyprint the resulting internal representation on standard output.",
      actionProcedure = liftIO . putStrLn . pretty
    }

-- | Print the result to stdout, alias annotations.
printAliasesAction :: (ASTLore lore, CanBeAliased (Op lore)) => Action lore
printAliasesAction =
  Action
    { actionName = "Prettyprint",
      actionDescription = "Prettyprint the resulting internal representation on standard output.",
      actionProcedure = liftIO . putStrLn . pretty . aliasAnalysis
    }

-- | Print metrics about AST node counts to stdout.
metricsAction :: OpMetrics (Op lore) => Action lore
metricsAction =
  Action
    { actionName = "Compute metrics",
      actionDescription = "Print metrics on the final AST.",
      actionProcedure = liftIO . putStr . show . progMetrics
    }

-- | Convert the program to sequential ImpCode and print it to stdout.
impCodeGenAction :: Action SeqMem
impCodeGenAction =
  Action
    { actionName = "Compile imperative",
      actionDescription = "Translate program into imperative IL and write it on standard output.",
      actionProcedure = liftIO . putStrLn . pretty . snd <=< ImpGenSequential.compileProg
    }

-- | Convert the program to GPU ImpCode and print it to stdout.
kernelImpCodeGenAction :: Action KernelsMem
kernelImpCodeGenAction =
  Action
    { actionName = "Compile imperative kernels",
      actionDescription = "Translate program into imperative IL with kernels and write it on standard output.",
      actionProcedure = liftIO . putStrLn . pretty . snd <=< ImpGenKernels.compileProgOpenCL
    }

-- | Convert the program to CPU multicore ImpCode and print it to stdout.
multicoreImpCodeGenAction :: Action MCMem
multicoreImpCodeGenAction =
  Action
    { actionName = "Compile to imperative multicore",
      actionDescription = "Translate program into imperative multicore IL and write it on standard output.",
      actionProcedure = liftIO . putStrLn . pretty . snd <=< ImpGenMulticore.compileProg
    }

cmdCC :: String
cmdCC = fromMaybe "cc" $ lookup "CC" unixEnvironment

cmdCFLAGS :: [String] -> [String]
cmdCFLAGS def = maybe def words $ lookup "CFLAGS" unixEnvironment

runCC :: String -> String -> [String] -> [String] -> FutharkM ()
runCC cpath outpath cflags_def ldflags = do
  ret <-
    liftIO $
      runProgramWithExitCode
        cmdCC
        ( [cpath, "-o", outpath]
            ++ cmdCFLAGS cflags_def
            ++
            -- The default LDFLAGS are always added.
            ldflags
        )
        mempty
  case ret of
    Left err ->
      externalErrorS $ "Failed to run " ++ cmdCC ++ ": " ++ show err
    Right (ExitFailure code, _, gccerr) ->
      externalErrorS $
        cmdCC ++ " failed with code "
          ++ show code
          ++ ":\n"
          ++ gccerr
    Right (ExitSuccess, _, _) ->
      return ()

cmdEMCC :: String
cmdEMCC = fromMaybe "emcc" $ lookup "emcc" unixEnvironment

runEMCC :: String -> String -> [String] -> [String] -> FutharkM ()
runEMCC cpath outpath cflags_def ldflags = do
  ret <-
    liftIO $
      runProgramWithExitCode
        cmdEMCC
        ( [cpath, "-o", outpath] 
            ++ ["-lnodefs.js", "-s", "ALLOW_MEMORY_GROWTH=1"]
            ++ cmdCFLAGS cflags_def
            ++
            -- The default LDFLAGS are always added.
            ldflags
        )
        mempty
  case ret of
    Left err ->
      externalErrorS $ "Failed to run " ++ cmdEMCC ++ ": " ++ show err
    Right (ExitFailure code, _, gccerr) ->
      externalErrorS $
        cmdEMCC ++ " failed with code "
          ++ show code
          ++ ":\n"
          ++ gccerr -- possibly need to change this to emccerr
    Right (ExitSuccess, _, _) ->
      return ()

-- | The @futhark c@ action.
compileCAction :: FutharkConfig -> CompilerMode -> FilePath -> Action SeqMem
compileCAction fcfg mode outpath =
  Action
    { actionName = "Compile to sequential C",
      actionDescription = "Compile to sequential C",
      actionProcedure = helper
    }
  where
    helper prog = do
      cprog <- handleWarnings fcfg $ SequentialC.compileProg prog
      let cpath = outpath `addExtension` "c"
          hpath = outpath `addExtension` "h"

      case mode of
        ToLibrary -> do
          let (header, impl) = SequentialC.asLibrary cprog
          liftIO $ writeFile hpath header
          liftIO $ writeFile cpath impl
        ToExecutable -> do
          liftIO $ writeFile cpath $ SequentialC.asExecutable cprog
          runCC cpath outpath ["-O3", "-std=c99"] ["-lm"]
        ToServer -> do
          liftIO $ writeFile cpath $ SequentialC.asServer cprog
          runCC cpath outpath ["-O3", "-std=c99"] ["-lm"]

compileCtoWASMAction :: FutharkConfig -> CompilerMode -> FilePath -> Action SeqMem
compileCtoWASMAction fcfg mode outpath =
  Action
    { actionName = "Compile to sequential C",
      actionDescription = "Compile to sequential C",
      actionProcedure = helper
    }
  where
    helper prog = do
      cprog <- handleWarnings fcfg $ SequentialC.compileProg prog
      let cpath = outpath `addExtension` "c"
          hpath = outpath `addExtension` "h"

      case mode of
        ToLibrary -> do
          let (h, imp) = SequentialC.asLibrary cprog
          liftIO $ writeFile hpath h
          liftIO $ writeFile cpath imp
        ToExecutable -> do
          liftIO $ writeFile cpath $ SequentialC.asExecutable cprog
          runEMCC cpath outpath ["-O3"] ["-lm"]

-- | The @futhark opencl@ action.
compileOpenCLAction :: FutharkConfig -> CompilerMode -> FilePath -> Action KernelsMem
compileOpenCLAction fcfg mode outpath =
  Action
    { actionName = "Compile to OpenCL",
      actionDescription = "Compile to OpenCL",
      actionProcedure = helper
    }
  where
    helper prog = do
      cprog <- handleWarnings fcfg $ COpenCL.compileProg prog
      let cpath = outpath `addExtension` "c"
          hpath = outpath `addExtension` "h"
          extra_options
            | System.Info.os == "darwin" =
              ["-framework", "OpenCL"]
            | System.Info.os == "mingw32" =
              ["-lOpenCL64"]
            | otherwise =
              ["-lOpenCL"]

      case mode of
        ToLibrary -> do
          let (header, impl) = COpenCL.asLibrary cprog
          liftIO $ writeFile hpath header
          liftIO $ writeFile cpath impl
        ToExecutable -> do
          liftIO $ writeFile cpath $ COpenCL.asExecutable cprog
          runCC cpath outpath ["-O", "-std=c99"] ("-lm" : extra_options)
        ToServer -> do
          liftIO $ writeFile cpath $ COpenCL.asServer cprog
          runCC cpath outpath ["-O", "-std=c99"] ("-lm" : extra_options)

-- | The @futhark cuda@ action.
compileCUDAAction :: FutharkConfig -> CompilerMode -> FilePath -> Action KernelsMem
compileCUDAAction fcfg mode outpath =
  Action
    { actionName = "Compile to CUDA",
      actionDescription = "Compile to CUDA",
      actionProcedure = helper
    }
  where
    helper prog = do
      cprog <- handleWarnings fcfg $ CCUDA.compileProg prog
      let cpath = outpath `addExtension` "c"
          hpath = outpath `addExtension` "h"
          extra_options =
            [ "-lcuda",
              "-lcudart",
              "-lnvrtc"
            ]
      case mode of
        ToLibrary -> do
          let (header, impl) = CCUDA.asLibrary cprog
          liftIO $ writeFile hpath header
          liftIO $ writeFile cpath impl
        ToExecutable -> do
          liftIO $ writeFile cpath $ CCUDA.asExecutable cprog
          runCC cpath outpath ["-O", "-std=c99"] ("-lm" : extra_options)
        ToServer -> do
          liftIO $ writeFile cpath $ CCUDA.asServer cprog
          runCC cpath outpath ["-O", "-std=c99"] ("-lm" : extra_options)

-- | The @futhark multicore@ action.
compileMulticoreAction :: FutharkConfig -> CompilerMode -> FilePath -> Action MCMem
compileMulticoreAction fcfg mode outpath =
  Action
    { actionName = "Compile to multicore",
      actionDescription = "Compile to multicore",
      actionProcedure = helper
    }
  where
    helper prog = do
      cprog <- handleWarnings fcfg $ MulticoreC.compileProg prog
      let cpath = outpath `addExtension` "c"
          hpath = outpath `addExtension` "h"

      case mode of
        ToLibrary -> do
          let (header, impl) = MulticoreC.asLibrary cprog
          liftIO $ writeFile hpath header
          liftIO $ writeFile cpath impl
        ToExecutable -> do
          liftIO $ writeFile cpath $ MulticoreC.asExecutable cprog
          runCC cpath outpath ["-O", "-std=c99"] ["-lm", "-pthread"]
        ToServer -> do
          liftIO $ writeFile cpath $ MulticoreC.asServer cprog
          runCC cpath outpath ["-O", "-std=c99"] ["-lm", "-pthread"]
