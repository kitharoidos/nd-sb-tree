{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}

{-|
Module      : Math.SternBrocotTree
Description : Branch-wise and generation-wise construction of the n-dimensional Stern-Brocot tree
Copyright   : (c) Michal Hadrava, 2017
License     : BSD3
Maintainer  : mihadra@gmail.com
Stability   : experimental
Portability : POSIX

This module implements the algorithm for branch-wise and generation-wise construction of the /n/-dimensional
Stern-Brocot tree due to Hakan Lennerstad as specified in \"The n-dimensional Stern-Brocot tree\", Blekige
Institute of Technology, Research report No. 2012:04.
-}
module Math.SternBrocotTree
    ( RatioN
    , treeToLevel
    , branchToRatio
    ) where

import Algebra.Graph as G (Graph, empty, overlay, overlays, vertex, edge)
import Control.Monad (replicateM, (>=>))
import Control.Monad.Loops (iterateUntil)
import Control.Monad.Freer (Eff, Member, Members, run, runM, send)
import Control.Monad.Freer.State (State, evalState, get, put)
import Control.Monad.Freer.Writer (Writer, runWriter, tell)
import Data.Foldable as F (toList)
import Data.List as L (subsequences, init, tail, map)
import Data.Monoid ()
import Data.Proxy (Proxy (..))
import Data.Vector as V hiding (replicateM)
import GHC.TypeLits (KnownNat)
import Linear.V (Finite, Size, reflectDim)
import Linear.Vector (Additive, basisFor)

data SBTree a = SBTree {toGraph :: Graph a} deriving (Show, Eq)

instance Monoid (SBTree a) where
    mempty = SBTree G.empty
    mappend (SBTree g) (SBTree g') = SBTree $ overlay g g'

-- | An /n/-part ratio, i.e. a node in the /n/-dimensional Stern-Brocot tree.
type RatioN r = (Additive r, Traversable r, Foldable r, Finite r, KnownNat (Size r), Num (r Int), Eq (r Int))

-- | Subtree of the /n/-dimensional Stern-Brocot tree extending down to the /m/th level (generation). The first
-- level corresponds to the ratio 1:1:...1.
treeToLevel :: RatioN r => Int    -- ^ /m/
    -> Graph (r Int)
treeToLevel 0 = G.empty
treeToLevel 1 = vertex 1
treeToLevel m = overlays . L.map toGraph . runTreeEff $ treeEff m

-- | Branch of the /n/-dimensional Stern-Brocot tree leading to the ratio /r/.
branchToRatio :: RatioN r => r Int -- ^ /r/
    -> Graph (r Int)
branchToRatio 1  = 1
branchToRatio r = toGraph $ runBranchEff r (branchEff r)


runTreeEff :: forall r. RatioN r =>
    Eff '[EdgeEff r, RatioEff r, IndexEff, []] [(r Int, r Int)] -> [SBTree (r Int)]
runTreeEff = runM . evalIndex (reflectDim (Proxy :: Proxy (Size r))) . runGraphEff

treeEff :: RatioN r =>
    Int -> Eff '[EdgeEff r, RatioEff r, IndexEff, []] [(r Int, r Int)]
treeEff = flip replicateM (indexEff >>= graphEff)


runBranchEff :: RatioN r =>
    r Int -> Eff '[EdgeEff r, RatioEff r, FactorEff] (r Int, r Int) -> SBTree (r Int)
runBranchEff r = run . evalFactor r . runGraphEff

branchEff :: RatioN r => r Int -> Eff '[EdgeEff r, RatioEff r, FactorEff] (r Int, r Int)
branchEff sq = iterateUntil ((== sq) . snd) (factorEff >>= graphEff)


runGraphEff :: RatioN r =>
    Eff (EdgeEff r ': RatioEff r ': effs) w -> Eff effs (SBTree (r Int))
runGraphEff = evalRatio . runEdge

graphEff :: (RatioN r, Members '[EdgeEff r, RatioEff r] effs) =>
    Vector Int -> Eff effs (r Int, r Int)
graphEff = ratioEff >=> edgeEff


type EdgeEff r = Writer (SBTree (r Int))

runEdge :: RatioN r => Eff (EdgeEff r ': effs) w -> Eff effs (SBTree (r Int))
runEdge = fmap snd . runWriter

edgeEff :: (RatioN r, Member (EdgeEff r) effs) => (r Int, r Int) -> Eff effs (r Int, r Int)
edgeEff e = do
    tell . SBTree $ uncurry edge e
    return e


type RatioEff r = State (r Int, Vector (r Int))

evalRatio :: RatioN r => Eff (RatioEff r ': effs) w -> Eff effs w
evalRatio = flip evalState (ones, basis)
    where ones  = 1
          basis = V.fromList $ basisFor ones

ratioEff :: (RatioN r, Member (RatioEff r) effs) => Vector Int -> Eff effs (r Int, r Int)
ratioEff indices = do
    (r, mat) <- get
    let mat' = cons r $ backpermute mat indices
        r'  = V.sum mat'
    put (r', mat')
    return (r, r')


type IndexEff = State Int

evalIndex :: Int -> Eff (IndexEff ': effs) w -> Eff effs w
evalIndex = flip evalState . subtract 1

indexEff :: (Members '[IndexEff, []] effs) => Eff effs (Vector Int)
indexEff = do
    n <- get
    indices <- send . L.map fromList . L.tail . L.init $ subsequences [0 .. n]
    put $ V.length indices
    return indices


type FactorEff = State (Vector Int)

evalFactor :: RatioN r => r Int -> Eff (FactorEff ': effs) w -> Eff effs w
evalFactor r = flip evalState (V.fromList $ F.toList r)

factorEff :: Member FactorEff effs => Eff effs (Vector Int)
factorEff = do
    (f :: Vector Int) <- get
    let fmin    = V.minimum f
        f'      = V.map (subtract fmin) f
        indices = V.filter ((> 0) . (f' !)) . enumFromN 0 $ V.length f'
    put . cons fmin $ backpermute f' indices
    return indices
