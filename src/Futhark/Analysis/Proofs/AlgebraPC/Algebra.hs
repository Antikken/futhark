module Futhark.Analysis.Proofs.AlgebraPC.Algebra
  ( IdxSym(..),
    Symbol(..),
    MonDir(..),
    Property(..),
    AlgM(..),
    runAlgM,
    hasPow,
    hasSum,
    hasIdxOrSum,
    hasMon
  ) 
where

import Control.Monad.RWS.Strict hiding (Sum)
import Data.Set qualified as S
import Futhark.Analysis.Proofs.Util (prettyName)
import Futhark.MonadFreshNames
import Futhark.SoP.Expression
import Futhark.SoP.Monad (AlgEnv (..), MonadSoP (..), Nameable (mkName))
import Futhark.SoP.SoP (SoP)
import Futhark.Util.Pretty (Pretty, brackets, parens, pretty, enclose, (<+>))
import Language.Futhark (VName)
import Language.Futhark qualified as E

data IdxSym
  = One VName
  -- ^ one regular name
  | POR (S.Set VName)
  -- ^ represents an OR of index-fun-predicates;
  --   implicit assumption: set's cardinal >= 2.
  deriving (Show, Eq, Ord) 

data Symbol
  = Var VName
  | Idx IdxSym (SoP Symbol)
  | Mdf MonDir VName (SoP Symbol) (SoP Symbol)
  -- ^ `Mdf dir A i1 i2` means `A[i1] - A[i2]` where
  -- `A` is known to be monotonic with direction `dir`
  | Sum IdxSym (SoP Symbol) (SoP Symbol)
  | Pow (Integer, SoP Symbol)
  -- ^ assumes positive exponents (i.e., >= 0);
  --   should be verified before construction
  deriving (Show, Eq, Ord)

instance Pretty IdxSym where
  pretty (One x ) = prettyName x
  pretty (POR xs) =
    iversonbrackets (mkPOR (S.toList xs))
    where
      iversonbrackets = enclose "⟦" "⟧"
      mkPOR [] = error "Illegal!"
      mkPOR [x] = pretty x
      mkPOR (x:y:lst) = pretty x <+> "||" <+> mkPOR (y:lst) 
    
instance Pretty Symbol where
  pretty symbol = case symbol of
    (Var x) -> prettyName x
    (Idx x i) -> (pretty x) <> brackets (pretty i)
    (Mdf _ x i1 i2) ->
      parens $
        ((prettyName x) <> (brackets (pretty i1)))
        <+> "-" <+> 
        ((prettyName x) <> (brackets (pretty i2)))
    (Sum x lb ub) ->
      "∑"
        <> pretty x
        <> brackets (pretty lb <+> ":" <+> pretty ub)
    (Pow (b,s)) -> parens $ prettyOp "^" b s
    where
      prettyOp s x y = pretty x <+> s <+> pretty y    
{--
      autoParens x@(Var _) = pretty x
      autoParens x@(Hole _) = pretty x
      autoParens x = parens (pretty x)
--}

data MonDir = Inc | IncS | Dec | DecS
  deriving (Show, Eq, Ord)

data Property
  = Monotonic MonDir
  | Injective
  deriving (Show, Eq, Ord)

data VEnv e = VEnv
  { vnamesource :: VNameSource,
    algenv :: AlgEnv Symbol e Property
  }

newtype AlgM e a = AlgM (RWS () () (VEnv e) a)
  deriving
    ( Applicative,
      Functor,
      Monad,
      MonadFreshNames,
      MonadState (VEnv e)
    )

instance (Monoid w) => MonadFreshNames (RWS r w (VEnv e)) where
  getNameSource = gets vnamesource
  putNameSource vns = modify $ \senv -> senv {vnamesource = vns}

-- This is required by MonadSoP.
instance Nameable Symbol where
  mkName (VNameSource i) = (Var $ E.VName "x" i, VNameSource $ i + 1)

instance (Expression e, Ord e) => MonadSoP Symbol e Property (AlgM e) where
  getUntrans = gets (untrans . algenv)
  getRanges = gets (ranges . algenv)
  getEquivs = gets (equivs . algenv)
  getProperties = gets (properties . algenv)
  modifyEnv f = modify $ \env -> env {algenv = f $ algenv env}

runAlgM :: AlgM e a -> AlgEnv Symbol e Property -> VNameSource -> (a, VEnv e)
runAlgM (AlgM m) env vns = getRes $ runRWS m () s
  where
    getRes (x, env1, _) = (x, env1)
    s = VEnv vns env

---------------------------------
--- Simple accessor functions ---
---------------------------------

hasPow :: Symbol -> Bool
hasPow (Pow _) = True
hasPow _ = False

hasSum :: Symbol -> Bool
hasSum (Sum{}) = True
hasSum _ = False

hasIdx :: Symbol -> Bool
hasIdx (Idx {}) = True
hasIdx (Mdf {}) = True
hasIdx _ = False

hasIdxOrSum :: Symbol -> Bool
hasIdxOrSum x = hasIdx x || hasSum x

hasMon :: S.Set Property -> Maybe MonDir
hasMon props
  | S.null props = Nothing
  | Monotonic dir:_ <- filter f (S.toList props) =
    Just dir
  where f (Monotonic _) = True
        f _ = False
hasMon _ = Nothing


{--
f :: (SoP Symbol >= 0) -> AlgM e Bool
f sop = do
  modifyEnv $ undefined
  undefined

runF :: (SoP Symbol >= 0) -> AlgEnv Symbol e Property -> VNameSource -> (Bool, VEnv e)
runF sop env vns= runAlgM (f sop) env vns

rules :: RuleBook (SoP Symbol) Symbol (AlgM e)
rules = []

(&<) :: (Expression e, Ord e) => SoP Symbol -> SoP Symbol ->  AlgM e Bool
sop1 &< sop2 = do
 prop  <- getProperties
 sop1 FM.$<$ sop2 -- fourier mo
 --}
