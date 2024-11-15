-- Index function substitution.
module Futhark.Analysis.Proofs.Substitute (($$)) where

import Control.Monad (unless)
import Data.Bifunctor (first)
import Data.Map qualified as M
import Data.Maybe (isJust, fromMaybe)
import Debug.Trace (traceM)
import Futhark.Analysis.Proofs.AlgebraBridge.Translate (rollbackAlgEnv)
import Futhark.Analysis.Proofs.AlgebraPC.Symbol qualified as Algebra
import Futhark.Analysis.Proofs.IndexFn
import Futhark.Analysis.Proofs.IndexFnPlus (domainEnd, domainStart, repCase, repIndexFn)
import Futhark.Analysis.Proofs.Monad
import Futhark.Analysis.Proofs.Rewrite (rewrite)
import Futhark.Analysis.Proofs.Symbol
import Futhark.Analysis.Proofs.SymbolPlus (toSumOfSums)
import Futhark.Analysis.Proofs.Traversals (ASTMapper (..), astMap, identityMapper)
import Futhark.Analysis.Proofs.Unify (Replaceable (..), Replacement, ReplacementBuilder (..), Substitution (..), Unify (..), fv, renameM, renameSame)
import Futhark.Analysis.Proofs.Util (prettyBinding')
import Futhark.MonadFreshNames (newName, newVName)
import Futhark.SoP.Monad (UntransEnv (dir), getUntrans, lookupUntransPE)
import Futhark.SoP.SoP (SoP, mapSymSoP, sym2SoP)
import Futhark.Util.Pretty (prettyString)
import Language.Futhark (VName)

-- We use an operator so as not to confuse it with substitution from Unify.
-- 'f $$ (x, g)' substitutes name 'x' for indexfn 'g' in indexfn 'f'.
($$) :: IndexFn -> (VName, IndexFn) -> IndexFnM IndexFn
f@(IndexFn (Forall j _) _) $$ (vn, g@(IndexFn (Forall i _) _)) = do
  whenDebug $
    traceM $
      "🎭  "
        <> prettyBinding' vn g
        <> prettyBinding' ("\n    into _" :: String) f
  _ <- inline (vn, g) f
  i' <- sym2SoP . Var <$> newName i
  (f', g') <- renameSame f g
  substitute vn (repIndexFn (mkRep i i') g') (repIndexFn (mkRep j i') f')
f $$ (vn, g@(IndexFn (Forall {}) _)) = do
  whenDebug $
    traceM $
      "🎭  "
        <> prettyBinding' vn g
        <> prettyBinding' ("\n    into _" :: String) f
  substitute vn g f
f $$ (vn, g) = substitute vn g f

sameRange :: Domain -> Domain -> IndexFnM Bool
sameRange dom_f dom_g = do
  start_f <- rewrite (domainStart dom_f)
  start_g <- rewrite (domainStart dom_g)
  end_f <- rewrite (domainEnd dom_f)
  end_g <- rewrite (domainEnd dom_g)
  eq_start :: Maybe (Substitution Symbol) <- unify start_f start_g
  eq_end :: Maybe (Substitution Symbol) <- unify end_f end_g
  pure $ isJust eq_start && isJust eq_end

assertSameRange :: Domain -> Domain -> IndexFnM ()
assertSameRange dom_f dom_g =
  sameRange dom_f dom_g >>= flip unless (error "checkSameRange: inequal ranges")

subIterator :: VName -> Cases Symbol (SoP Symbol) -> Iterator -> Iterator
subIterator _ _ Empty = Empty
subIterator x_fn xs iter@(Forall i dom) =
  if x_fn `elem` fv dom
    then case casesToList xs of
      [(Bool True, x_val)] ->
        Forall i $
          case dom of
            Iota n -> Iota $ mapSymSoP (rip x_fn i x_val) n
            Cat k m b -> Cat k (mapSymSoP (rip x_fn i x_val) m) (mapSymSoP (rip x_fn i x_val) b)
      _ -> error "substitute: substituting into domain using non-scalar index fn"
    else iter

-- Assumes that Forall-variables (i) of non-Empty iterators are equal.
substitute :: VName -> IndexFn -> IndexFn -> IndexFnM IndexFn
substitute x_fn (IndexFn Empty xs) (IndexFn iter_y ys) =
  -- Substitute scalar `x` into index function `y`.
  pure $
    IndexFn
      (subIterator x_fn xs iter_y)
      ( cases $ do
          (x_cond, x_val) <- casesToList xs
          (y_cond, y_val) <- casesToList ys
          pure $ repCase (mkRep x_fn x_val) (y_cond :&& x_cond, y_val)
      )
substitute x_fn (IndexFn (Forall i (Iota _)) xs) (IndexFn Empty ys) =
  -- Substitute array `x` into scalar `y` (type-checker ensures that this is valid,
  -- e.g., y is a sum).
  pure $
    IndexFn
      Empty
      ( cases $ do
          (x_cond, x_val) <- casesToList xs
          (y_cond, y_val) <- casesToList ys
          let rip_x = rip x_fn i x_val
          pure (sop2BoolSymbol . rip_x $ y_cond :&& x_cond, mapSymSoP rip_x y_val)
      )
substitute x_fn (IndexFn (Forall i dom_x) xs) (IndexFn (Forall _ dom_y) ys) = do
  case (dom_x, dom_y) of
    (Iota {}, Iota {}) -> do
      assertSameRange dom_x dom_y
      mkfn dom_y
    (Cat {}, Cat {}) -> do
      assertSameRange dom_x dom_y
      mkfn dom_y
    (Cat {}, Iota {}) -> do
      assertSameRange dom_x dom_y
      mkfn dom_x
    (Iota {}, Cat _ m _) -> do
      test1 <- sameRange dom_x dom_y
      test2 <- sameRange dom_x (Iota m)
      unless (test1 || test2) $ error "substitute iota cat: Incompatible domains."
      mkfn dom_y
  where
    mkfn dom =
      pure $
        IndexFn
          { iterator = subIterator x_fn xs $ Forall i dom,
            body = cases $ do
              (x_cond, x_val) <- casesToList xs
              (y_cond, y_val) <- casesToList ys
              let rip_x = rip x_fn i x_val
              pure (sop2BoolSymbol . rip_x $ y_cond :&& x_cond, mapSymSoP rip_x y_val)
          }
substitute _ x y = error $ "substitute: not implemented for " <> prettyString x <> prettyString y

-- TODO Sad that we basically have to copy rep here;
--      everything but the actual substitutions could be delegated to
--      a helper function that takes a replacement as argument?
rip :: VName -> VName -> SoP Symbol -> Symbol -> SoP Symbol
rip f_name f_arg f_val = apply mempty
  where
    applySoP = mapSymSoP . apply

    apply :: Replacement Symbol -> Symbol -> SoP Symbol
    apply s (Apply (Var x) [idx])
      | x == f_name =
          rep (M.insert f_arg idx s) f_val
    apply s (Idx (Var x) idx)
      | x == f_name =
          rep (M.insert f_arg idx s) f_val
    apply s (Var x)
      | x == f_name =
          rep s f_val
    apply _ x@(Var _) = sym2SoP x
    apply _ x@(Hole _) = sym2SoP x
    apply s (Idx x idx) =
      sym2SoP $ Idx (sop2Symbol $ apply s x) (applySoP s idx)
    apply s (Sum j lb ub x) =
      let s' = addRep j (Var j) s
       in toSumOfSums j (applySoP s' lb) (applySoP s' ub) (apply s' x)
    apply s (Apply f xs) =
      sym2SoP $ Apply (sop2Symbol $ apply s f) (map (applySoP s) xs)
    apply s (Tuple xs) =
      sym2SoP $ Tuple (map (applySoP s) xs)
    apply _ x@(Bool _) = sym2SoP x
    apply _ Recurrence = sym2SoP Recurrence
    apply s sym = case sym of
      Not x -> sym2SoP . neg . sop2BoolSymbol $ apply s x
      x :< y -> binop (:<) x y
      x :<= y -> binop (:<=) x y
      x :> y -> binop (:>) x y
      x :>= y -> binop (:>=) x y
      x :== y -> binop (:==) x y
      x :/= y -> binop (:/=) x y
      x :&& y -> binopS (:&&) x y
      x :|| y -> binopS (:||) x y
      where
        binop op x y = sym2SoP $ applySoP s x `op` applySoP s y
        binopS op x y = sym2SoP $ sop2BoolSymbol (apply s x) `op` sop2BoolSymbol (apply s y)

-- XXX sub f into g
-- 1. find applications:
--    traverse AST:
--      if subsymbol is application site f[e(i)]:
--        NOTE guard against applications using quantified variables. (See below.)
--        vn_f_app <- fresh name
--        replace f[e(i)] by Var vn
--        collect (vn_f_app, e(i))
-- 2. for each application (vn_f_app, e(i)) in applications:
--      for each case (x_cond, x_val) in g:
--        for each case (y_cond, y_val) in f:
--          z_val = y_val{ vn_f_app |-> x_val{i |-> e(i)} }
--          z_cond = y_cond{ vn_f_app |-> x_val{i |-> e(i)} }
--          changed = y_cond /= z_cond || y_val /= z_val
--          z_cond' = if changed then x_cond{i |-> e(i)} :&& z_cond else z_cond
--          in (z_cond', z_val)
--      if vn_f_app in domain of g:
--         substitute here also, fail if f has more than one case (don't support "outer-ifs" atm).
--
-- XXX guard against substituting indexing using quantified variables, e.g., sum_j xs[j]:
-- 1. before traversing AST, create fresh name k
-- 2. rename throughout AST
-- 3. at xs[idx]: if fv(idx) contains any variable >= k, then
--    we are indexing using a quantifier and should fail.
--    (Unless xs has only one case | True => x_val, then
--    we could do the substiution.)
-- 4. to mitigate failing cases we can try to substitute
--    before rewriting recurrences to sums
-- This leads us to:
--
-- XXX when to rewrite recurrences as sums?
-- When substitituting a recurrent index fn into some other index fn.
-- When querying the solver about an index fn (won't actually alter the representation of it).
-- ==> That is, NOT unless we have to.
--
-- XXX could we rewrite recurrences in terms of the index fn being substituted into?

inline :: (VName, IndexFn) -> IndexFn -> IndexFnM IndexFn
inline (f_name, f) g = do
  k <- newVName "variables after this are quantifiers"
  g' <- renameM g
  let notQuantifier = (< k)
  let legalName v = notQuantifier v || Just v == getCatIteratorVariable g' || hasSingleCase f
  -- 1. Collect applications
  -- TODO Reusing algenv for collecting here; should probably make another entry in VEnv instead.
  (h, apps) <- rollbackAlgEnv $ do
    clearAlgEnv
    g'' <- astMap (identityMapper {mapOnSymbol = repAppByName legalName}) g'
    as <- map (first Algebra.getVName) . M.assocs . dir <$> getUntrans
    pure (g'', (f_name, Var f_name) : as)
  debugPrettyM "inline h:" h
  debugPrettyM "inline apps:" apps
  pure h
  where
    -- Replace applications of f by (fresh) names.
    -- We disallow substituting f into sums, if f has more than one case
    -- (it would be unclear what case value to substitute). This is enforced
    -- by checking for captured quantifiers in the function argument,
    -- for example, Sum_j (f[i] + j) is allowed, but Sum_j (f[j]) is not.
    -- (Unless f only has one case.)
    repAppByName legalName sym = case sym of
      Apply (Var x) [idx]
        | x == f_name,
          legalIdx idx ->
            repByName (Idx (Var x) idx)
      Idx (Var x) idx
        | x == f_name,
          legalIdx idx ->
          do
            debugPrettyM "repByName idx" idx
            debugPrettyM "repByName fv idx" (fv idx)
            repByName (Idx (Var x) idx)
      Apply (Var x) [_]
        | x == f_name -> error "Capturing variables"
      Idx (Var x) _
        | x == f_name -> error "Capturing variables"
      _ -> pure sym
      where
        legalIdx = all legalName . fv

    repByName app = do
      f_at_idx <- Algebra.getVName <$> lookupUntransPE app
      pure (Var f_at_idx)
