-- | Generating metadata so that programs can run at all.
module Futhark.Internalise.Entry
  ( entryPoint,
    VisibleTypes,
    visibleTypes,
  )
where

import Control.Monad
import Control.Monad.State.Strict
import Data.Bifunctor (first)
import Data.List (find, intersperse)
import Data.Map qualified as M
import Futhark.IR qualified as I
import Futhark.Internalise.TypesValues (internaliseSumTypeRep, internalisedTypeSize)
import Futhark.Util (chunks)
import Futhark.Util.Pretty (prettyTextOneLine)
import Language.Futhark qualified as E hiding (TypeArg)
import Language.Futhark.Core (L (..), Name, Uniqueness (..), VName, nameFromText, unLoc)
import Language.Futhark.Semantic qualified as E

-- | The types that are visible to the outside world.
newtype VisibleTypes = VisibleTypes [E.TypeBind]

-- | Retrieve those type bindings that should be visible to the
-- outside world.  Currently that is everything at top level that does
-- not have type parameters.
visibleTypes :: E.Imports -> VisibleTypes
visibleTypes = VisibleTypes . foldMap (modTypes . snd)
  where
    modTypes = progTypes . E.fileProg
    progTypes = foldMap decTypes . E.progDecs
    decTypes (E.TypeDec tb) = [tb]
    decTypes _ = []

findType :: VName -> VisibleTypes -> Maybe (E.TypeExp E.Exp VName)
findType v (VisibleTypes ts) = E.typeExp <$> find ((== v) . E.typeAlias) ts

valueType :: I.TypeBase I.Rank Uniqueness -> I.ValueType
valueType (I.Prim pt) = I.ValueType I.Signed (I.Rank 0) pt
valueType (I.Array pt rank _) = I.ValueType I.Signed rank pt
valueType I.Acc {} = error "valueType Acc"
valueType I.Mem {} = error "valueType Mem"

withoutDims :: E.TypeExp E.Exp VName -> (Int, E.TypeExp E.Exp VName)
withoutDims (E.TEArray _ te _) =
  let (d, te') = withoutDims te
   in (d + 1, te')
withoutDims te = (0 :: Int, te)

rootType :: E.TypeExp E.Exp VName -> E.TypeExp E.Exp VName
rootType (E.TEApply te E.TypeArgExpSize {} _) = rootType te
rootType (E.TEUnique te _) = rootType te
rootType (E.TEDim _ te _) = rootType te
rootType (E.TEParens te _) = rootType te
rootType te = te

typeExpOpaqueName :: E.TypeExp E.Exp VName -> Name
typeExpOpaqueName = nameFromText . f
  where
    f = g . rootType
    g (E.TEArray _ te _) =
      let (d, te') = withoutDims te
       in mconcat (replicate (1 + d) "[]") <> f te'
    g (E.TETuple tes _) =
      "(" <> mconcat (intersperse ", " (map f tes)) <> ")"
    g (E.TERecord tes _) =
      "{" <> mconcat (intersperse ", " (map onField tes)) <> "}"
      where
        onField (L _ k, te) = E.nameToText k <> ":" <> f te
    g (E.TESum cs _) =
      mconcat (intersperse " | " (map onConstr cs))
      where
        onConstr (k, tes) =
          E.nameToText k <> ":" <> mconcat (intersperse " " (map f tes))
    g (E.TEParens te _) = "(" <> f te <> ")"
    g te = prettyTextOneLine te

type GenOpaque = State I.OpaqueTypes

runGenOpaque :: GenOpaque a -> (a, I.OpaqueTypes)
runGenOpaque = flip runState mempty

addType :: Name -> I.OpaqueType -> GenOpaque ()
addType name t = modify $ \(I.OpaqueTypes ts) ->
  case find ((== name) . fst) ts of
    Just (_, t')
      | t /= t' ->
          error . unlines $
            [ "Duplicate definition of entry point type " <> E.prettyString name,
              show t,
              show t'
            ]
    _ -> I.OpaqueTypes ts <> I.OpaqueTypes [(name, t)]

isRecord ::
  VisibleTypes ->
  E.TypeExp E.Exp VName ->
  Maybe (M.Map Name (E.TypeExp E.Exp VName))
isRecord _ (E.TERecord fs _) = Just $ M.fromList $ map (first unLoc) fs
isRecord _ (E.TETuple fs _) = Just $ E.tupleFields fs
isRecord types (E.TEVar v _) = isRecord types =<< findType (E.qualLeaf v) types
isRecord _ _ = Nothing

recordFields ::
  VisibleTypes ->
  M.Map Name E.StructType ->
  Maybe (E.TypeExp E.Exp VName) ->
  [(Name, E.EntryType)]
recordFields types fs t =
  case isRecord types . rootType =<< t of
    Just e_fs ->
      zipWith f (E.sortFields fs) (E.sortFields e_fs)
      where
        f (k, f_t) (_, e_f_t) = (k, E.EntryType f_t $ Just e_f_t)
    Nothing ->
      map (fmap (`E.EntryType` Nothing)) $ E.sortFields fs

opaqueRecord ::
  VisibleTypes ->
  [(Name, E.EntryType)] ->
  [I.TypeBase I.Rank Uniqueness] ->
  GenOpaque [(Name, I.EntryPointType)]
opaqueRecord _ [] _ = pure []
opaqueRecord types ((f, t) : fs) ts = do
  let (f_ts, ts') = splitAt (internalisedTypeSize $ E.entryType t) ts
  f' <- opaqueField t f_ts
  ((f, f') :) <$> opaqueRecord types fs ts'
  where
    opaqueField e_t i_ts = snd <$> entryPointType types e_t i_ts

opaqueRecordArray ::
  VisibleTypes ->
  Int ->
  [(Name, E.EntryType)] ->
  [I.TypeBase I.Rank Uniqueness] ->
  GenOpaque [(Name, I.EntryPointType)]
opaqueRecordArray _ _ [] _ = pure []
opaqueRecordArray types rank ((f, t) : fs) ts = do
  let (f_ts, ts') = splitAt (internalisedTypeSize $ E.entryType t) ts
  f' <- opaqueField t f_ts
  ((f, f') :) <$> opaqueRecordArray types rank fs ts'
  where
    opaqueField (E.EntryType e_t _) i_ts =
      snd <$> entryPointType types (E.EntryType e_t' Nothing) i_ts
      where
        e_t' = E.arrayOf (E.Shape (replicate rank E.anySize)) e_t

isSum ::
  VisibleTypes ->
  E.TypeExp E.Exp VName ->
  Maybe (M.Map Name [E.TypeExp E.Exp VName])
isSum _ (E.TESum cs _) = Just $ M.fromList cs
isSum types (E.TEVar v _) = isSum types =<< findType (E.qualLeaf v) types
isSum _ _ = Nothing

sumConstrs ::
  VisibleTypes ->
  M.Map Name [E.StructType] ->
  Maybe (E.TypeExp E.Exp VName) ->
  [(Name, [E.EntryType])]
sumConstrs types cs t =
  case isSum types . rootType =<< t of
    Just e_cs ->
      zipWith f (E.sortConstrs cs) (E.sortConstrs e_cs)
      where
        f (k, c_ts) (_, e_c_ts) = (k, zipWith E.EntryType c_ts $ map Just e_c_ts)
    Nothing ->
      map (fmap (map (`E.EntryType` Nothing))) $ E.sortConstrs cs

opaqueSum ::
  VisibleTypes ->
  [(Name, ([E.EntryType], [Int]))] ->
  [I.TypeBase I.Rank Uniqueness] ->
  GenOpaque [(Name, [(I.EntryPointType, [Int])])]
opaqueSum types cs ts = mapM (traverse f) cs
  where
    f (ets, is) = do
      let ns = map (internalisedTypeSize . E.entryType) ets
          is' = chunks ns is
      ets' <- map snd <$> zipWithM (entryPointType types) ets (map (map (ts !!)) is')
      pure $ zip ets' $ map (map (+ 1)) is' -- Adjust for tag.

entryPointTypeName :: I.EntryPointType -> Name
entryPointTypeName (I.TypeOpaque v) = v
entryPointTypeName (I.TypeTransparent {}) = error "entryPointTypeName: TypeTransparent"

elemTypeExp :: E.TypeExp E.Exp VName -> Maybe (E.TypeExp E.Exp VName)
elemTypeExp (E.TEArray _ te _) = Just te
elemTypeExp (E.TEUnique te _) = elemTypeExp te
elemTypeExp (E.TEParens te _) = elemTypeExp te
elemTypeExp _ = Nothing

rowTypeExp :: Int -> E.TypeExp E.Exp VName -> Maybe (E.TypeExp E.Exp VName)
rowTypeExp 0 te = Just te
rowTypeExp r te = rowTypeExp (r - 1) =<< elemTypeExp te

entryPointType ::
  VisibleTypes ->
  E.EntryType ->
  [I.TypeBase I.Rank Uniqueness] ->
  GenOpaque (Uniqueness, I.EntryPointType)
entryPointType types t ts
  | E.Scalar (E.Prim E.Unsigned {}) <- E.entryType t,
    [I.Prim ts0] <- ts =
      pure (u, I.TypeTransparent $ I.ValueType I.Unsigned (I.Rank 0) ts0)
  | E.Array _ _ (E.Prim E.Unsigned {}) <- E.entryType t,
    [I.Array ts0 r _] <- ts =
      pure (u, I.TypeTransparent $ I.ValueType I.Unsigned r ts0)
  | E.Scalar E.Prim {} <- E.entryType t,
    [I.Prim ts0] <- ts =
      pure (u, I.TypeTransparent $ I.ValueType I.Signed (I.Rank 0) ts0)
  | E.Array _ _ E.Prim {} <- E.entryType t,
    [I.Array ts0 r _] <- ts =
      pure (u, I.TypeTransparent $ I.ValueType I.Signed r ts0)
  | otherwise = do
      case E.entryType t of
        E.Scalar (E.Record fs)
          | not $ null fs -> do
              let fs' = recordFields types fs $ E.entryAscribed t
              addType desc . I.OpaqueRecord =<< opaqueRecord types fs' ts
        E.Scalar (E.Sum cs) -> do
          let (_, places) = internaliseSumTypeRep cs
              cs' = sumConstrs types cs $ E.entryAscribed t
              cs'' = zip (map fst cs') (zip (map snd cs') (map snd places))
          addType desc . I.OpaqueSum (map valueType ts)
            =<< opaqueSum types cs'' (drop 1 ts)
        E.Array _ shape (E.Record fs)
          | not $ null fs -> do
              let fs' = recordFields types fs $ E.entryAscribed t
                  rank = E.shapeRank shape
                  ts' = map (strip rank) ts
                  record_t = E.Scalar (E.Record fs)
                  record_te = rowTypeExp rank =<< E.entryAscribed t
              ept <- snd <$> entryPointType types (E.EntryType record_t record_te) ts'
              addType desc . I.OpaqueRecordArray rank (entryPointTypeName ept)
                =<< opaqueRecordArray types rank fs' ts
        E.Array _ shape et -> do
          let ts' = map (strip (E.shapeRank shape)) ts
              rank = E.shapeRank shape
              elem_te = rowTypeExp rank =<< E.entryAscribed t
          ept <- snd <$> entryPointType types (E.EntryType (E.Scalar et) elem_te) ts'
          addType desc . I.OpaqueArray (E.shapeRank shape) (entryPointTypeName ept) $
            map valueType ts
        _ -> addType desc $ I.OpaqueType $ map valueType ts

      pure (u, I.TypeOpaque desc)
  where
    u = foldl max Nonunique $ map I.uniqueness ts
    desc =
      maybe (nameFromText $ prettyTextOneLine t') typeExpOpaqueName $
        E.entryAscribed t
    t' = E.noSizes (E.entryType t) `E.setUniqueness` Nonunique
    strip k (I.Array pt (I.Rank r) t_u) =
      I.arrayOf (I.Prim pt) (I.Rank (r - k)) t_u
    strip _ ts_t = ts_t

entryPoint ::
  VisibleTypes ->
  Name ->
  [(E.EntryParam, [I.Param I.DeclType])] ->
  ( E.EntryType,
    [[I.TypeBase I.Rank I.Uniqueness]]
  ) ->
  (I.EntryPoint, I.OpaqueTypes)
entryPoint types name params (eret, crets) =
  runGenOpaque $
    (name,,)
      <$> mapM onParam params
      <*> ( map (uncurry I.EntryResult)
              <$> case ( E.isTupleRecord $ E.entryType eret,
                         E.entryAscribed eret
                       ) of
                (Just ts, Just (E.TETuple e_ts _)) ->
                  zipWithM
                    (entryPointType types)
                    (zipWith E.EntryType ts (map Just e_ts))
                    crets
                (Just ts, Nothing) ->
                  zipWithM
                    (entryPointType types)
                    (map (`E.EntryType` Nothing) ts)
                    crets
                _ ->
                  pure <$> entryPointType types eret (concat crets)
          )
  where
    onParam (E.EntryParam e_p e_t, ps) =
      uncurry (I.EntryParam e_p)
        <$> entryPointType types e_t (map (I.rankShaped . I.paramDeclType) ps)
