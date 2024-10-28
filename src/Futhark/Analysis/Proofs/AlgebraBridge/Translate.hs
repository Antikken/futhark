-- Translation between Algebra and IndexFn layers.
module Futhark.Analysis.Proofs.AlgebraBridge.Translate
  ( toAlgebra,
    fromAlgebra,
    rollbackAlgEnv,
    algebraContext,
    toAlgebraSymbol,
  )
where

import Control.Monad (unless, (<=<), when)
import Data.Map qualified as M
import Data.Maybe (catMaybes, fromJust)
import Data.Set qualified as S
import Futhark.Analysis.Proofs.AlgebraPC.Symbol qualified as Algebra
import Futhark.Analysis.Proofs.Monad (IndexFnM, VEnv (algenv), debugPrettyM2)
import Futhark.Analysis.Proofs.Symbol (Symbol (..), isBoolean)
import Futhark.Analysis.Proofs.SymbolPlus ()
import Futhark.Analysis.Proofs.Traversals (ASTMappable, ASTMapper (..), astMap)
import Futhark.Analysis.Proofs.Unify (Substitution (mapping), rep, unify)
import Futhark.MonadFreshNames (newVName)
import Futhark.SoP.Convert (ToSoP (toSoPNum))
import Futhark.SoP.Monad (addProperty, addRange, getUntrans, inv, lookupUntransPE, lookupUntransSym, mkRange, askProperty)
import Futhark.SoP.SoP (SoP, int2SoP, justSym, mapSymSoP2M, mapSymSoP2M_, sym2SoP, (.+.), (~-~))
import Futhark.Util.Pretty (prettyString)
import Language.Futhark (VName)
import Control.Monad.RWS (gets, modify)

rollbackAlgEnv :: IndexFnM a -> IndexFnM a
rollbackAlgEnv computation = do
  alg <- gets algenv
  res <- computation
  modify (\env -> env {algenv = alg})
  pure res

-- Do this action inside an Algebra "context" created for this AST, ensuring:
-- (1) Modifications to the Algebra environment are ephemeral; they are
-- rolled back once the action is done.
-- (2) Translations of symbols in the AST are idempotent across environment
-- rollbacks. For example, in
-- ```
--   do
--     x <- rollbackAlgEnv $ toAlgebra (Sum xs[a:b])
--     y <- rollbackAlgEnv $ toAlgebra (Sum xs[a:b])
--     ...
-- ```
-- x and y may be different (e.g., sums over different fresh names). But in
-- ```
--   algebraContext (Sum xs[a:b]) $ do
--     x <- rollbackAlgEnv $ toAlgebra (Sum xs[a:b])
--     y <- rollbackAlgEnv $ toAlgebra (Sum xs[a:b])
--     ...
-- ```
-- x and y are identical.
-- TODO might be possible to make rollbackAlgEnv more lenient, so as not
-- to roll back the untranslatable environment? Then this function
-- can be removed. On the other hand, since we are often doing a linear search
-- in that env, it may be nice have it cleared.
-- TODO make this the "soft" rollback, that leaves in place the untranslatable
-- environment. And then switch the use of algebraContext and rollbackAlgEnv.
-- This way translations can be shared between branches and handleQuantifiers
-- only called once; less work, I guess.
algebraContext :: ASTMappable Symbol a => a -> IndexFnM b -> IndexFnM b
algebraContext x m = rollbackAlgEnv $ do
  _ <- handleQuantifiers x
  m

-----------------------------------------------------------------------------
-- Translation from Algebra to IndexFn layer.
------------------------------------------------------------------------------
fromAlgebra :: SoP Algebra.Symbol -> IndexFnM (SoP Symbol)
fromAlgebra = mapSymSoP2M fromAlgebra_

fromAlgebra_ :: Algebra.Symbol -> IndexFnM (SoP Symbol)
fromAlgebra_ (Algebra.Var vn) = do
  x <- lookupUntransSym (Algebra.Var vn)
  case x of
    Just x' -> pure . sym2SoP $ x'
    Nothing -> pure . sym2SoP $ Var vn
fromAlgebra_ (Algebra.Idx (Algebra.One vn) i) = do
  x <- lookupUntransSym (Algebra.Var vn)
  idx <- fromAlgebra i
  case x of
    Just x' -> sym2SoP <$> repHoles x' idx
    Nothing -> pure . sym2SoP $ Idx (Var vn) idx
fromAlgebra_ (Algebra.Idx (Algebra.POR vns) i) = do
  foldr1 (.+.)
    <$> mapM
      (\vn -> fromAlgebra_ $ Algebra.Idx (Algebra.One vn) i)
      (S.toList vns)
fromAlgebra_ (Algebra.Mdf _dir vn i j) = do
  -- TODO add monotonicity property to environment?
  a <- fromAlgebra i
  b <- fromAlgebra j
  x <- lookupUntransSymUnsafe vn
  xa <- repHoles x a
  xb <- repHoles x b
  pure $ xa ~-~ xb
fromAlgebra_ (Algebra.Sum (Algebra.One vn) lb ub) = do
  a <- fromAlgebra lb
  b <- fromAlgebra ub
  x <- lookupUntransSymUnsafe vn
  j <- newVName "j"
  xj <- repHoles x (sym2SoP $ Var j)
  pure . sym2SoP $ Sum j a b xj
fromAlgebra_ (Algebra.Sum (Algebra.POR vns) lb ub) = do
  -- Sum (POR {x,y}) a b = Sum x a b + Sum y a b
  foldr1 (.+.)
    <$> mapM
      (\vn -> fromAlgebra_ $ Algebra.Sum (Algebra.One vn) lb ub)
      (S.toList vns)
fromAlgebra_ (Algebra.Pow {}) = undefined

lookupUntransSymUnsafe :: VName -> IndexFnM Symbol
lookupUntransSymUnsafe = fmap fromJust . lookupUntransSym . Algebra.Var

-- Replace holes in `x` by `replacement`.
repHoles :: (Monad m) => Symbol -> SoP Symbol -> m Symbol
repHoles x replacement =
  astMap mapper x
  where
    -- Change how we are replacing depending on if replacement is really a SoP.
    mapper
      | Just replacement' <- justSym replacement =
          ASTMapper
            { mapOnSymbol = \sym -> case sym of
                Hole _ -> pure replacement'
                _ -> pure sym,
              mapOnSoP = pure
            }
      | otherwise =
          ASTMapper
            { mapOnSymbol = pure,
              mapOnSoP = \sop -> case justSym sop of
                Just (Hole _) -> pure replacement
                _ -> pure sop
            }

instance ToSoP Algebra.Symbol Symbol where
  -- Convert from IndexFn Symbol to Algebra Symbol.
  -- toSoPNum symbol = (1,) . sym2SoP <$> toAlgebra symbol
  toSoPNum symbol = error $ "toSoPNum used on " <> prettyString symbol

-----------------------------------------------------------------------------
-- Translation from IndexFn to Algebra layer.
------------------------------------------------------------------------------
toAlgebra :: SoP Symbol -> IndexFnM (SoP Algebra.Symbol)
toAlgebra = mapSymSoP2M_ toAlgebra_ <=< handleQuantifiers

toAlgebraSymbol :: Symbol -> IndexFnM Algebra.Symbol
toAlgebraSymbol = toAlgebra_ <=< handleQuantifiers

-- Replace bound variable `k` in `e` by Hole.
removeQuantifier :: Symbol -> VName -> IndexFnM Symbol
e `removeQuantifier` k = do
  hole <- sym2SoP . Hole <$> newVName "h"
  pure . fromJust . justSym $ rep (M.insert k hole mempty) e

-- Add quantified symbols to the untranslatable environement
-- with quantifiers replaced by holes. Subsequent lookups
-- must be done using `search`.
handleQuantifiers :: (ASTMappable Symbol b) => b -> IndexFnM b
handleQuantifiers = astMap m
  where
    m = ASTMapper {mapOnSymbol = handleQuant, mapOnSoP = pure}
    handleQuant sym@(Sum j _ _ x) = do
      res <- search x
      case res of
        Just _ -> pure sym
        Nothing -> do
          vn <- addUntrans =<< x `removeQuantifier` j
          booltype <- isBooleanM x
          when booltype $ addProperty (Algebra.Var vn) Algebra.Boolean
          pure sym
    handleQuant x = pure x

-- Search for hole-less symbol in untranslatable environment, matching
-- any symbol in the environment that is syntactically identical up to one hole.
-- For example, `search x[0]` in environment `{y : x[hole]}`,
-- returns `(y, (hole, 0)`.
search :: Symbol -> IndexFnM (Maybe (VName, Maybe (VName, SoP Symbol)))
search x = do
  inv_map <- inv <$> getUntrans
  case inv_map M.!? x of
    Just algsym ->
      -- Symbol is a key in untranslatable env.
      pure $ Just (Algebra.getVName algsym, Nothing)
    Nothing -> do
      -- Search for symbol in untranslatable environment; if x unifies
      -- with some key in the environment, return that key.
      -- Otherwise create a new entry in the environment.
      let syms = M.toList inv_map
      matches <- catMaybes <$> mapM (\(sym, algsym) -> fmap (algsym,) <$> unify sym x) syms
      case matches of
        [] -> pure Nothing
        [(algsym, sub)] -> do
          unless (M.size (mapping sub) == 1) $ error "search: multiple holes"
          pure $
            Just (Algebra.getVName algsym, Just . head $ M.toList (mapping sub))
        _ -> error "search: symbol unifies with multiple symbols"

isBooleanM :: Symbol -> IndexFnM Bool
isBooleanM (Var vn) = do
  askProperty (Algebra.Var vn) Algebra.Boolean
isBooleanM (Idx (Var vn) _) = do
  askProperty (Algebra.Var vn) Algebra.Boolean
isBooleanM (Apply (Var vn) _) = do
  askProperty (Algebra.Var vn) Algebra.Boolean
isBooleanM x = pure $ isBoolean x

idxSym :: Bool -> VName -> Algebra.IdxSym
idxSym True = Algebra.POR . S.singleton
idxSym False = Algebra.One

-- Translate IndexFn.Symbol to Algebra.Symbol.
-- Fresh names are created for untranslatable symbols such as indicators
-- and quantified symbols in sums. Indexing is preserved on untranslatable
-- symbols. For example, ⟦x[0] + 1⟧ + ∑j∈(1 .. b) ⟦x[j] + 1⟧ will be translated
-- as y[0] + Sum y[1:b] with fresh name y mapped to ⟦x[hole] + 1⟧.
-- This is done so because the algebra layer needs to know about indexing.
toAlgebra_ :: Symbol -> IndexFnM Algebra.Symbol
toAlgebra_ (Var x) = pure $ Algebra.Var x
toAlgebra_ (Hole _) = undefined
toAlgebra_ (Sum _ lb ub x) = do
  res <- search x
  case res of
    Just (vn, _) -> do
      a <- mapSymSoP2M_ toAlgebra_ lb
      b <- mapSymSoP2M_ toAlgebra_ ub
      booltype <- askProperty (Algebra.Var vn) Algebra.Boolean
      pure $ Algebra.Sum (idxSym booltype vn) a b
    Nothing -> error "handleQuantifiers need to be run"
toAlgebra_ sym@(Idx xs i) = do
  j <- mapSymSoP2M_ toAlgebra_ i
  res <- search sym
  vn <- case res of
    Just (vn, _) -> pure vn
    Nothing -> addUntrans xs
  booltype <- askProperty (Algebra.Var vn) Algebra.Boolean
  pure $ Algebra.Idx (idxSym booltype vn) j
-- toAlgebra_ (Indicator p) = handleBoolean p
toAlgebra_ sym@(Apply (Var f) [x]) = do
  res <- search sym
  vn <- case fst <$> res of
    Nothing -> addUntrans sym
    Just vn' -> pure vn'
  let idx = case snd =<< res of
        Nothing -> x
        Just (_hole, x') -> x'
  f_is_bool <- askProperty (Algebra.Var f) Algebra.Boolean
  when f_is_bool $ addProperty (Algebra.Var vn) Algebra.Boolean
  booltype <- askProperty (Algebra.Var vn) Algebra.Boolean
  idx' <- mapSymSoP2M_ toAlgebra_ idx
  pure $ Algebra.Idx (idxSym booltype vn) idx'

toAlgebra_ (Apply {}) = undefined
toAlgebra_ Recurrence = lookupUntransPE Recurrence
-- The rest are boolean statements; handled like indicator.
toAlgebra_ x = handleBoolean x

handleBoolean :: Symbol -> IndexFnM Algebra.Symbol
handleBoolean p = do
  res <- search p
  vn <- case fst <$> res of
    Nothing -> addUntrans p
    Just vn -> pure vn
  addRange (Algebra.Var vn) (mkRange (int2SoP 0) (int2SoP 1))
  addProperty (Algebra.Var vn) Algebra.Boolean
  case snd =<< res of
    Just (_hole, idx) -> do
      idx' <- mapSymSoP2M_ toAlgebra_ idx
      pure $ Algebra.Idx (Algebra.POR (S.singleton vn)) idx'
    Nothing -> pure $ Algebra.Var vn

addUntrans :: Symbol -> IndexFnM VName
addUntrans (Var vn) = pure vn
addUntrans sym = Algebra.getVName <$> lookupUntransPE sym
