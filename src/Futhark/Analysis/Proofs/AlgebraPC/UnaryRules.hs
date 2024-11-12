-- | Precise simplificaion rules for one pattern.
--   Examples include multiplication of Pow Symbols
--   and peeling off known Indexes from the beginning
--   or end of sum-of-slices.
module Futhark.Analysis.Proofs.AlgebraPC.UnaryRules
  ( simplifyPows,
    simplifyOneSumBef,
    simplifyOneSumAft
  )
where

import Control.Monad
import Data.Map.Strict qualified as M
import Data.Maybe
import Data.MultiSet qualified as MS
import Data.Set qualified as S
import Futhark.Analysis.Proofs.AlgebraPC.Symbol
import Futhark.SoP.SoP
import Futhark.SoP.Monad (MonadSoP, getEquivs, getProperties)  -- lookupRange
import Futhark.SoP.FourierMotzkin qualified as FM
import Language.Futhark (VName)


import Futhark.Util.Pretty
import Debug.Trace

-----------------------------------------
--- 1. Simplifications related to Pow ---
-----------------------------------------

simplifyPows ::
  (MonadSoP Symbol e p m) =>
  (SoP Symbol  -> m (SoP Symbol)) -> SoP Symbol -> m (SoP Symbol)
simplifyPows simplifyLevel sop = do
  lst <- mapM simplifyTerm $ M.toList $ getTerms sop
  pure $ normalize $ SoP $ foldl ff M.empty lst
  -- pure $ SoP $ M.fromList lst   -- BIG BUG!!!
  -- pure $ foldl (.+.) sop_zero $ map (\ (t,i) -> term2SoP t i) lst
  where
    ff acc (t,i) =
      case M.lookup t acc of
        Nothing -> M.insert t i acc
        Just j  -> M.insert t (i+j) acc
    -- simplifyTerm :: (Term Symbol, Integer) -> AlgM e (Term Symbol, Integer)
    simplifyTerm (Term mset, k) = do
      let (mset_pows, mset_others) = MS.partition hasPow mset
          mset_tup_pows = MS.mapMaybe mpowAsTup mset_pows
          lst_pows = map normalizePow $ MS.toOccurList mset_tup_pows
          (k', map_pows') = foldl combineSamePow (k, M.empty) lst_pows
      mset_pows'' <-
        forM (M.toList map_pows') $ \(b, p_sop) -> do
          p_sop' <- simplifyLevel p_sop
          -- \^ we simplify the exponents
          pure $ Pow (b, p_sop')
      pure $ (Term (MS.fromList mset_pows'' <> mset_others), k')
    --
    normalizePow :: ((Integer, SoP Symbol), Int) -> (Integer, SoP Symbol)
    normalizePow ((base, expnt), p) =
      (base, (int2SoP (fromIntegral p)) .*. expnt)
    mpowAsTup :: Symbol -> Maybe (Integer, SoP Symbol)
    mpowAsTup (Pow (base, expnt)) = Just (base, expnt)
    mpowAsTup _ = Nothing

combineSamePow ::
  (Integer, M.Map Integer (SoP Symbol)) ->
  (Integer, SoP Symbol) ->
  (Integer, M.Map Integer (SoP Symbol))
combineSamePow (q, tab) (b, sop) =
  let (q', sop') =
        case getPowOfFactor q b of
          (_, 0) -> (q, sop)
          (r, p) -> (r, int2SoP p .+. sop)
      sop'' = maybe sop' (.+. sop') $ M.lookup b tab
   in (q', M.insert b sop'' tab)
  where
    getPowOfFactor :: Integer -> Integer -> (Integer, Integer)
    getPowOfFactor qq bb = getPowOfFactorTR qq bb 0
    getPowOfFactorTR qq bb pr
      | qq `mod` bb /= 0 = (qq, pr)
    getPowOfFactorTR qq bb pr =
      getPowOfFactorTR (qq `div` bb) bb (pr + 1)

---------------------------------------------------------------
--- 2. Pre Simplification of each (individual) slice sum:   ---
---      i.e., before applying binary simplifications       ---
---    2.1. sum x[lb .. ub] => 0     whenever lb  > ub      ---
---    2.2. uniting a "potentially nicely-empty slice" with ---
---           a first/last known element. This requires FM  ---
---           to check nicety:  ub - lb + 1 >= 0            ---
---------------------------------------------------------------

sop_one :: SoP Symbol
sop_one = int2SoP 1

sop_zero :: SoP Symbol
sop_zero = int2SoP 0

type FoldFunTp m =
      Maybe (SoP Symbol, Symbol) ->
      (Symbol, Int) ->
      m (Maybe (SoP Symbol, Symbol))

simplifyOneSumBef ::
  (MonadSoP Symbol e p m) => SoP Symbol -> m (Bool, SoP Symbol)
simplifyOneSumBef sop = do
  equivs <- getEquivs
  sop'   <- elimEmptySums sop
  (success, sop'') <- unaryOpOnSumFP (hasUnitingSums equivs) uniteSumSym sop'
  pure (success, sop'')

hasUnitingSums :: M.Map Symbol (SoP Symbol) -> (SoP Symbol) -> Bool
hasUnitingSums equivs =
  any hasUnitingSumSym . S.toList . free
  where
    hasUnitingSumSym (Sum (POR nms) beg end)
      | S.size nms > 1 =
      any hasUnitingSumSym $
        map (\nm -> Sum (POR (S.singleton nm)) beg end) $
        S.toList nms
    hasUnitingSumSym (Sum nm beg end) =
      isJust (M.lookup (Idx nm (beg .-. sop_one)) equivs)
        || isJust (M.lookup (Idx nm (end .+. sop_one)) equivs)
    hasUnitingSumSym _ = False

uniteSumSym :: (MonadSoP Symbol e p m) => FoldFunTp m
uniteSumSym acc@(Just {}) _ = pure acc
uniteSumSym Nothing (sym@(Sum nm beg end), 1) = do
  -- \^ ToDo: extend for any multiplicity >= 1
  equivs <- getEquivs
  valid_slice <- beg FM.$<=$ (end .+. sop_one)
  let beg_m_1 = beg .-. sop_one
      end_p_1 = end .+. sop_one
      -- \^ do we need to further simplify these?
  mfst_el <- getEquivSoP equivs $ Idx nm beg_m_1
  mlst_el <- getEquivSoP equivs $ Idx nm end_p_1
  case (valid_slice, mfst_el, mlst_el) of
    (False, _, _) ->
      pure Nothing
    (True, Just fst_el, Nothing) -> do
      let new_sum = Sum nm beg_m_1 end
      pure $ Just (sym2SoP new_sum .-. fst_el, sym)
    (True, Nothing, Just lst_el) -> do
      let new_sum = Sum nm beg end_p_1
      pure $ Just (sym2SoP new_sum .-. lst_el, sym)
    (True, Just fst_el, Just lst_el) -> do
      let new_sum = Sum nm beg_m_1 end_p_1
      pure $ Just (sym2SoP new_sum .-. (fst_el .+. lst_el), sym)
    (True, Nothing, Nothing) -> pure Nothing
uniteSumSym Nothing _ = pure Nothing

-- | Transforms a "known" array index to its value,
--   by looking it up in the table of equivalences.
getEquivSoP :: (MonadSoP Symbol e p m) => 
  M.Map Symbol (SoP Symbol) -> Symbol -> m (Maybe (SoP Symbol))
getEquivSoP equivs symb@(Idx (POR nms) ind_sop)
  | S.size nms > 1,
    syms  <- map (nm2PORsym ind_sop) $ S.toList nms,
    eq_vs <- mapMaybe (`M.lookup` equivs) syms =
  if not $ null $ filter (== sop_one) eq_vs
  then pure $ Just sop_one
  -- \^ we found a True term in an OR node => True
  else if length eq_vs == length syms &&
          all (== sop_zero) eq_vs
       then pure $ Just sop_zero
       -- \^ all are zero
       else pure $ M.lookup symb equivs
  where
    nm2PORsym ind arr_nm = Idx (POR (S.singleton arr_nm)) ind
getEquivSoP equivs symb@Idx{} =
  pure $ M.lookup symb equivs
{--
      | Just eq_v <- M.lookup symb equivs = do
      Range elm_lb m elm_ub <- lookupRange $ Var arr_nm
      let elm_bds = if k > 0 then elm_ub else elm_lb
          eq_v_m = if m == 1 then eq_v else eq_v .*. int2SoP m
      if any (== eq_v_m) $ S.toList elm_bds
      -- \^ ToDo: here we should check by means of Fourier-Motzking
      --      (1) In k*t > 0 case: any (eq_v FM.$>=$ ub) elm_ub 
      --      (2) In k*t < 0 case: any (eq_v FM.$<=$ lb) elm_lb
      then pure $ Just eq_v
      else pure Nothing
--}
getEquivSoP _ _ =
  pure Nothing

---------------------------------------------------------------
--- 2. Post Simplification of each (individual) slice sum:  ---
---    2.1. sum x[lb .. ub] => 0     whenever lb  > ub      ---
---    2.2. sum x[lb .. ub] => x[lb] whenever lb == ub      ---
---    2.3. peeling off first/last known elements of a sum  ---
---         ToDo: this case requires checking that slice is ---
---               not empty by FM.                          ---
---------------------------------------------------------------

simplifyOneSumAft ::
  (MonadSoP Symbol e Property m) => SoP Symbol -> m (Bool, SoP Symbol)
simplifyOneSumAft sop = do
  equivs <- getEquivs
  sop' <- elimEmptySums sop
  let (succ1, sop'') = transfSum2Idx sop'
  (succ2, sop''') <- unaryOpOnSumFP (hasPeelableSums equivs) peelSumSymb sop''
  pure (succ1 || succ2, sop''')

transfSum2Idx :: SoP Symbol -> (Bool, SoP Symbol)
transfSum2Idx sop
  | tgt_sums <- filter isOneElmSum $ S.toList $ free sop,
    not (null tgt_sums) =
  let subs = M.fromList $ zip tgt_sums $ map sum2Idx tgt_sums
  in  (True, substitute subs sop)
  where
    isOneElmSum (Sum _ lb ub) = lb == ub
    isOneElmSum _ = False
    sum2Idx (Sum idxsym lb _) = Idx idxsym lb
    sum2Idx _ = error "Unreachable case reached in transfSum2Idx."
transfSum2Idx sop = (False, sop)

hasPeelableSums :: M.Map Symbol (SoP Symbol) -> (SoP Symbol) -> Bool
hasPeelableSums equivs = (\ _ -> True)
  -- any hasPeelableSumSym . S.toList . free
  -- \^ has to make it look inside POR nodes
  where
    hasPeelableSumSym (Sum nm beg end) =
      isJust (M.lookup (Idx nm beg) equivs)
        || isJust (M.lookup (Idx nm end) equivs)
    hasPeelableSumSym _ = False

disjointAllTheWay :: M.Map Symbol (S.Set Property) -> S.Set VName -> Bool
disjointAllTheWay tab_props nms
  | S.size nms > 1,
    nm <- S.elemAt 0 nms,
    mtmp <- M.lookup (Var nm) tab_props,
    Just nms_disjoint <- hasDisjoint (fromMaybe S.empty mtmp) =
  nms == S.insert nm nms_disjoint
disjointAllTheWay _ _ =
  False

-- | Several cases:
--   Case 1 (SUM): 
--     If x DISJOINT (y,z) holds and also
--        ub - lb + 1 >= 0 holds
--     then Sum(x||y||z)[lb,ub] == ub - lb + 1
--   Case 2 (IDX): similar with Case 1 but for an index.
--   Case 3 (SUM): 
--     peeling off first/last known elements of a sum
--     (requires non-empty slice)
--   Case 4 (IDX): similar to Case 2 but for index.
peelSumSymbHelper :: (MonadSoP Symbol e Property m) =>
  M.Map Symbol (S.Set Property) -> Symbol -> m (Maybe (SoP Symbol, Symbol))
peelSumSymbHelper tab_props sym@(Idx (POR nms) _idx)
  | disjointAllTheWay tab_props nms = do -- Case 2
  pure $ Just (sop_one, sym)
--
peelSumSymbHelper tab_props sym@(Sum (POR nms) beg end)
  | disjointAllTheWay tab_props nms = do -- Case 1
  let end_p_1 = end .+. sop_one
  valid_slice <- beg FM.$<=$ end_p_1
  if valid_slice
  then pure $ Just $ (end_p_1 .-. beg, sym)
  else pure Nothing
--
peelSumSymbHelper _ sym@(Sum arr beg end) = do -- Case 3
  equivs <- getEquivs
  non_empty_slice <- beg FM.$<=$ end
  mfst_el <- getEquivSoP equivs $ Idx arr beg
  mlst_el <- getEquivSoP equivs $ Idx arr end
  --  mfst_el = M.lookup (Idx arr beg) equivs
  --  mlst_el = M.lookup (Idx arr end) equivs
  case (non_empty_slice, mfst_el, mlst_el) of
    (False, _, _) ->
      pure Nothing
    (True, Just fst_el, Nothing) -> do
      let new_sum = Sum arr (beg .+. sop_one) end
      pure $ Just (fst_el .+. sym2SoP new_sum, sym)
    (True, Nothing, Just lst_el) -> do
      let new_sum = Sum arr beg (end .-. sop_one)
      pure $ Just (lst_el .+. sym2SoP new_sum, sym)
    (True, Just fst_el, Just lst_el) -> do
      let new_sum = Sum arr (beg .+. sop_one) (end .-. sop_one)
      pure $ Just (fst_el .+. lst_el .+. sym2SoP new_sum, sym)
    (True, Nothing, Nothing) -> pure Nothing
--
peelSumSymbHelper _ sym@(Idx arr idx) = do -- Case 4
  equivs <- getEquivs
  m_el   <- getEquivSoP equivs $ Idx arr idx
  case m_el of
    Nothing -> pure Nothing
    Just el -> pure $ Just (el, sym)
--
peelSumSymbHelper _ _ =
  pure Nothing
  
peelSumSymb :: (MonadSoP Symbol e Property m) => FoldFunTp m
peelSumSymb acc@(Just {}) _ = pure acc
peelSumSymb Nothing (sym, 1) = do
  -- \^ ToDo: extend for any multiplicity >= 1
  tab_props <- getProperties
  peelSumSymbHelper tab_props sym
{--
peelSumSymb Nothing (sym@(Sum arr beg end), 1) = do
  -- \^ ToDo: extend for any multiplicity >= 1
  equivs <- getEquivs
  non_empty_slice <- beg FM.$<=$ end
  mfst_el <- getEquivSoP equivs $ Idx arr beg
  mlst_el <- getEquivSoP equivs $ Idx arr end
  --  mfst_el = M.lookup (Idx arr beg) equivs
  --  mlst_el = M.lookup (Idx arr end) equivs
  case (non_empty_slice, mfst_el, mlst_el) of
    (False, _, _) ->
      pure Nothing
    (True, Just fst_el, Nothing) -> do
      let new_sum = Sum arr (beg .+. sop_one) end
      pure $ Just (fst_el .+. sym2SoP new_sum, sym)
    (True, Nothing, Just lst_el) -> do
      let new_sum = Sum arr beg (end .-. sop_one)
      pure $ Just (lst_el .+. sym2SoP new_sum, sym)
    (True, Just fst_el, Just lst_el) -> do
      let new_sum = Sum arr (beg .+. sop_one) (end .-. sop_one)
      pure $ Just (fst_el .+. lst_el .+. sym2SoP new_sum, sym)
    (True, Nothing, Nothing) -> pure Nothing
--}
peelSumSymb Nothing _ = pure Nothing

-- ToDo: add an extra rule for:
-- assume x DISJOINT (y,z) and
-- Sum(x||y||z)[lb,ub] ==> ub - lb + 1 in case ub - lb + 1 >= 0

----------------------------------------
--- Common Infrastructure for Unary  ---
--- Simplifications of Sum of Slice  ---
----------------------------------------

elimEmptySums :: 
  (MonadSoP Symbol e p m) => SoP Symbol -> m (SoP Symbol)
elimEmptySums sop = do
  sopFromList <$> (filterM predTerm $ sopToList sop)
  where
    emptySumSym (Sum _ lb ub) = lb FM.$>$ ub
    emptySumSym _ = pure False
    predTerm (Term ms, _) = do
      tmps <- mapM (emptySumSym . fst) $ MS.toOccurList ms
      pure $ all not tmps

unaryOpOnSumFP :: (MonadSoP Symbol e p m) =>
  (SoP Symbol -> Bool) -> FoldFunTp m -> SoP Symbol -> m (Bool, SoP Symbol)
unaryOpOnSumFP hasOpOnSym opOnSym sop
  | hasOpOnSym sop = do
  res <- unaryOpOnSum opOnSym sop
  case res of
    (False, _) -> pure (False, sop)
    (True, sop') -> do -- fix point
      (_, sop'') <- unaryOpOnSumFP hasOpOnSym opOnSym sop'
      pure (True, sop'')
  where
unaryOpOnSumFP _ _ sop = pure (False, sop)

unaryOpOnSum :: (MonadSoP Symbol e p m) => FoldFunTp m -> SoP Symbol -> m (Bool, SoP Symbol)
unaryOpOnSum opOnSym sop = do
  res <- foldM opOnTerm Nothing (M.toList (getTerms sop))
  case res of
    Nothing -> pure (False, sop)
    Just (old_term_sop, new_sop) ->
      pure (True, (sop .-. old_term_sop) .+. new_sop)
  where
    opOnTerm acc@(Just {}) _ = pure acc
    opOnTerm Nothing (t, k) = do
      mres <- foldM opOnSym Nothing $ MS.toOccurList $ getTerm t
      case mres of
        Nothing -> pure Nothing
        Just (sop_sym, sum_sym) -> do
          let ms' = MS.delete sum_sym $ getTerm t
              sop' = sop_sym .*. term2SoP (Term ms') k
          pure $ Just (term2SoP t k, sop')


