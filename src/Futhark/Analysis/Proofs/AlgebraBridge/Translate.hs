-- Translation between Algebra and IndexFn layers.
module Futhark.Analysis.Proofs.AlgebraBridge.Translate
  ( toAlgebra,
    fromAlgebra,
    rollbackAlgEnv,
    algebraContext,
    toAlgebraSymbol,
    isBooleanM,
  )
where

import Control.Monad (foldM, forM_, unless, void, when, (<=<))
import Control.Monad.RWS (gets, modify)
import Data.Map qualified as M
import Data.Maybe (catMaybes, fromJust, fromMaybe, isNothing)
import Data.Set qualified as S
import Futhark.Analysis.Proofs.AlgebraPC.Symbol qualified as Algebra
import Futhark.Analysis.Proofs.IndexFn (IndexFn, Iterator (Forall), getIterator, getPredicates)
import Futhark.Analysis.Proofs.Monad (IndexFnM, VEnv (algenv), debugPrettyM)
import Futhark.Analysis.Proofs.Symbol (Symbol (..), isBoolean)
import Futhark.Analysis.Proofs.SymbolPlus ()
import Futhark.Analysis.Proofs.Traversals (ASTMappable, ASTMapper (..), astMap)
import Futhark.Analysis.Proofs.Unify (Substitution (mapping), mkRep, rep, unify)
import Futhark.MonadFreshNames (newVName)
import Futhark.SoP.Convert (ToSoP (toSoPNum))
import Futhark.SoP.Monad (addEquiv, addProperty, addRange, askProperty, getUntrans, inv, lookupUntransPE, lookupUntransSym, mkRange, substEquivs)
import Futhark.SoP.SoP (SoP, int2SoP, justSym, mapSymSoP2M, mapSymSoP2M_, sym2SoP, (.+.), (~-~))
import Futhark.Util.Pretty (prettyString)
import Language.Futhark (VName)

rollbackAlgEnv :: IndexFnM a -> IndexFnM a
rollbackAlgEnv computation = do
  alg <- gets algenv
  res <- computation
  modify (\env -> env {algenv = alg})
  pure res

-- Do this action inside an Algebra "context" created for an IndexFn, ensuring:
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
algebraContext :: IndexFn -> IndexFnM b -> IndexFnM b
algebraContext fn m = rollbackAlgEnv $ do
  let ps = getPredicates fn
  mapM_ trackBooleanNames ps
  _ <- handleQuantifiers fn
  case getIterator fn of
    Just (Forall i _) -> do
      mapM_ (handlePreds i) ps
      addDisjointedness i ps
    _ -> pure ()
  m
  where
    lookupUntransBool i x = do
      res <- search x
      vn <- case fst <$> res of
        Nothing -> addUntrans =<< x `removeQuantifier` i
        Just vn -> pure vn
      addRange (Algebra.Var vn) (mkRange (int2SoP 0) (int2SoP 1))
      addProperty (Algebra.Var vn) Algebra.Boolean
      pure vn

    -- c[i] == y && d[i] => {c[i] == y: p[hole1], d[i]: q[hole2]}
    handlePreds i (x :&& y) = handlePreds i x >> handlePreds i y
    handlePreds i (x :|| y) = handlePreds i x >> handlePreds i y
    handlePreds i x = lookupUntransBool i x

    addDisjointedness _ ps | length ps < 2 = pure ()
    addDisjointedness i ps = do
      -- If p is on the form p && q, then p and q probably already
      -- have untranslatable names, but p && q does not. The PairwiseDisjoint
      -- set, however, needs to be complete in the sense that OR'ing every
      -- element in the set is a tautology. So we need to create a
      -- name for the predicate with connectives.
      vns <- mapM (lookupUntransBool i) ps
      forM_ vns $ \vn ->
        addProperty (Algebra.Var vn) $
          Algebra.PairwiseDisjoint (S.fromList vns S.\\ S.singleton vn)

    -- Add boolean tag to IndexFn layer names where applicable.
    trackBooleanNames (Var vn) = do
      addProperty (Algebra.Var vn) Algebra.Boolean
    trackBooleanNames (Idx (Var vn) _) = do
      addProperty (Algebra.Var vn) Algebra.Boolean
    trackBooleanNames (Apply (Var vn) _) = do
      addProperty (Algebra.Var vn) Algebra.Boolean
    trackBooleanNames (Not x) = trackBooleanNames x
    trackBooleanNames (x :&& y) = trackBooleanNames x >> trackBooleanNames y
    trackBooleanNames (x :|| y) = trackBooleanNames x >> trackBooleanNames y
    trackBooleanNames _ = pure ()

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
-- returns `(y, 0)`, implying hole maps to 0.
search :: Symbol -> IndexFnM (Maybe (VName, Maybe (SoP Symbol)))
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
            Just (Algebra.getVName algsym, Just . head $ M.elems (mapping sub))
        _ ->
          error $ "search: " <> prettyString x <> " unifies with multiple symbols"

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
-- Fresh names are created for untranslatable symbols such as boolean expressions
-- and quantified symbols in sums. Indexing is preserved on untranslatable
-- symbols. For example, ⟦x[0] + 1⟧ + ∑j∈(1 .. b) ⟦x[j] + 1⟧ will be translated
-- as y[0] + Sum y[1:b] with fresh name y mapped to ⟦x[hole] + 1⟧.
-- This is done so because the algebra layer needs to know about indexing.
toAlgebra_ :: Symbol -> IndexFnM Algebra.Symbol
toAlgebra_ (Var x) = pure $ Algebra.Var x
toAlgebra_ (Hole _) = undefined
toAlgebra_ (Sum j lb ub x) = do
  res <- search x
  case res of
    Just (vn, match) -> do
      let idx = fromMaybe (sym2SoP $ Var j) match
      a <- mapSymSoP2M_ toAlgebra_ (rep (mkRep j lb) idx)
      b <- mapSymSoP2M_ toAlgebra_ (rep (mkRep j ub) idx)
      booltype <- askProperty (Algebra.Var vn) Algebra.Boolean
      pure $ Algebra.Sum (idxSym booltype vn) a b
    Nothing -> error "handleQuantifiers need to be run"
toAlgebra_ sym@(Idx (Var xs) i) = do
  res <- search sym
  vn <- case fst <$> res of
    Just vn -> pure vn
    Nothing -> addUntrans (Var xs)
  let idx = fromMaybe i (snd =<< res)
  idx' <- mapSymSoP2M_ toAlgebra_ idx
  booltype <- askProperty (Algebra.Var vn) Algebra.Boolean
  pure $ Algebra.Idx (idxSym booltype vn) idx'
toAlgebra_ (Idx {}) = undefined
toAlgebra_ sym@(Apply (Var f) [x]) = do
  res <- search sym
  vn <- case fst <$> res of
    Just vn -> pure vn
    Nothing -> addUntrans sym
  let idx = fromMaybe x (snd =<< res)
  idx' <- mapSymSoP2M_ toAlgebra_ idx
  f_is_bool <- askProperty (Algebra.Var f) Algebra.Boolean
  when f_is_bool $ addProperty (Algebra.Var vn) Algebra.Boolean
  booltype <- askProperty (Algebra.Var vn) Algebra.Boolean
  pure $ Algebra.Idx (idxSym booltype vn) idx'
toAlgebra_ x@(Apply {}) = lookupUntransPE x
toAlgebra_ x@(Tuple {}) =
  error $ "toAlgebra_: " <> prettyString x -- XXX unzip before getting here!
toAlgebra_ Recurrence = lookupUntransPE Recurrence
-- The rest are boolean statements.
toAlgebra_ x = handleBoolean x

handleBoolean :: Symbol -> IndexFnM Algebra.Symbol
handleBoolean (Bool p) = do
  x <- lookupUntransPE (Bool p)
  addEquiv x (int2SoP $ boolToInt p)
  pure x
  where
    boolToInt True = 1
    boolToInt False = 0
handleBoolean p = do
  res <- search p
  vn <- case fst <$> res of
    Nothing -> addUntrans p
    Just vn -> pure vn
  addRange (Algebra.Var vn) (mkRange (int2SoP 0) (int2SoP 1))
  addProperty (Algebra.Var vn) Algebra.Boolean
  case snd =<< res of
    Just idx -> do
      idx' <- mapSymSoP2M_ toAlgebra_ idx
      pure $ Algebra.Idx (Algebra.POR (S.singleton vn)) idx'
    Nothing -> pure $ Algebra.Var vn

addUntrans :: Symbol -> IndexFnM VName
addUntrans (Var vn) = pure vn
addUntrans sym = Algebra.getVName <$> lookupUntransPE sym
