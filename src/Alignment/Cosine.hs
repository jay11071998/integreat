{- Alignment.Cosine
Gregory W. Schwartz

Collections the functions pertaining to getting integration by cosine
similarity.
-}

{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PackageImports #-}

module Alignment.Cosine
    ( cosineIntegrate
    , cosineSim
    , cosineSimIMap
    , cosinePerm
    , cosineBoot
    ) where

-- Standard
import Control.Monad
import Data.List
import Data.Maybe
import Data.Monoid
import Data.Tuple
import qualified Data.IntMap.Strict as IMap

-- Cabal
import Control.Concurrent.Async
import Control.Lens
import Data.Random
import Numeric.LinearAlgebra hiding ((<>))
import Statistics.Resampling
import Statistics.Resampling.Bootstrap
import "statistics" Statistics.Types
import System.Random.MWC (createSystemRandom)
import qualified Control.Foldl as Fold
import qualified Data.Text as T
import qualified Data.Vector as VB
import qualified Data.Vector.Generic as VG
import qualified Data.Vector.Unboxed as VU

-- Local
import Types
import Utility

-- | Get the cosine similarity of two levels.
cosineIntegrate :: Permutations
                -> Size
                -> VertexSimMap
                -> LevelName
                -> LevelName
                -> EdgeSimMatrix
                -> EdgeSimMatrix
                -> IO NodeCorrScores
cosineIntegrate nPerm size vMap l1 l2 e1 e2 = do
    let newE1 :: IMap.IntMap (IMap.IntMap Double)
        newE1     = unEdgeSimMatrix
                  . cosineUpdateSimMat e1
                  . unVertexSimValues
                  $ vertexSim
        newE2 :: IMap.IntMap (IMap.IntMap Double)
        newE2     = unEdgeSimMatrix
                  . cosineUpdateSimMat e2
                  . unVertexSimValues
                  $ vertexSim
        vertexSim = getVertexSim l1 l2 vMap

    fmap ( NodeCorrScores
         . VB.fromList
         . fmap snd
         . IMap.toAscList
         . fillIntMap size
         )
        . mapConcurrently (uncurry (cosineBoot nPerm size))
        . fmap (over both IntMapContainer)
        . IMap.intersectionWith (,) newE1
        $ newE2

-- | Update the similarity matrices where the diagonal contains the similarity
-- between vertices of different levels.
cosineUpdateSimMat :: EdgeSimMatrix -> [((Int, Int), Double)] -> EdgeSimMatrix
cosineUpdateSimMat (EdgeSimMatrix edgeSimMat) =
    EdgeSimMatrix
        . foldl' (\acc ((!x, !y), !z) -> IMap.alter (f y z) x acc) edgeSimMat
        . (\xs -> xs ++ fmap (over _1 swap) xs)
  where
    f y z Nothing  = Just . IMap.singleton y $ z
    f y z (Just v) = Just . IMap.insert y z $ v

-- | Cosine similarity.
cosineSim :: Vector Double -> Vector Double -> Double
cosineSim x y = dot x y / (norm_2 x * norm_2 y)

-- | Cosine similarity of two IntMaps.
cosineSimIMap :: IMap.IntMap Double -> IMap.IntMap Double -> Double
cosineSimIMap x y = (imapSum $ IMap.intersectionWith (*) x y)
                  / (imapNorm x * imapNorm y)
  where
    imapNorm = sqrt . imapSum . IMap.map (^ 2)
    imapSum  = IMap.foldl' (+) 0

-- | Cosine similarity of a foldable of tuples.
cosineSimFold :: (Foldable f) => f (Double, Double) -> Double
cosineSimFold = Fold.fold cosine
  where
    cosine = (/) <$> num <*> den
    num = Fold.Fold (\acc (x, y) -> acc + (x * y)) 0 id
    den = (*) <$> norm fst <*> norm snd
    norm f = Fold.Fold (\acc x -> acc + ((f x) ^ 2)) 0 sqrt

-- | Cosine similarity of an unboxed vector.
cosineSimVec :: VU.Vector (Double, Double) -> Double
cosineSimVec xs = num / den
  where
    num  = VU.sum . VU.map (\(!x, !y) -> x * y) $ xs
    den  = (norm . VU.map fst $ xs) * (norm . VU.map snd $ xs)
    norm = sqrt . VU.sum . VU.map (^ 2)

-- | Get the cosine similarity and the p value of that similarity through the
-- permutation test by shuffling non-zero edges of the second vertex.
cosinePerm :: Permutations
           -> IMap.IntMap Double
           -> IMap.IntMap Double
           -> IO (Double, Maybe Statistic)
cosinePerm (Permutations nPerm) xs ys = do
    let obs     = cosineSimIMap xs ys
        expTest = (>= abs obs) . abs

    let successes :: Int -> Int -> IO Int
        successes !acc 0  = return acc
        successes !acc !n = do
            res <-  shuffleCosine xs $ ys
            if expTest res
                then successes (acc + 1) (n - 1)
                else successes acc (n - 1)

    exp <- successes 0 nPerm

    let pVal = PValue $ (fromIntegral exp) / (fromIntegral nPerm)

    return (obs, Just pVal)

-- | Get the cosine similarity and the p value of that similarity through the
-- permutation test, using the edge distribution from the second network.
cosinePermFromDist
    :: Permutations
    -> EdgeValues
    -> IMap.IntMap Double
    -> IMap.IntMap Double
    -> IO (Double, Maybe Statistic)
cosinePermFromDist (Permutations nPerm) edgeVals xs ys = do
    let obs     = cosineSimIMap xs ys
        expTest = (>= abs obs) . abs
        successes :: Int -> Int -> IO Int
        successes !acc 0  = return acc
        successes !acc !n = do
            res <- randomCosine edgeVals xs $ ys
            if expTest res
                then successes (acc + 1) (n - 1)
                else successes acc (n - 1)

    exp <- successes 0 nPerm

    let pVal = PValue $ (fromIntegral exp) / (fromIntegral nPerm)

    return (obs, Just pVal)

-- | Get the cosine similarity and the bootstrap using the edge distribution
-- from the second network. These are special IntMaps where the key is the index
-- of a sparse vector.
cosineBoot
    :: Permutations
    -> Size
    -> VectorType
    -> VectorType
    -> IO (Double, Maybe Statistic)
cosineBoot (Permutations nPerm) (Size size) xs ys = do
    let obs            = case (xs, ys) of
                            (IntMapContainer !xs, IntMapContainer !ys) -> cosineSimIMap xs ys
                            (VectorContainer !xs, VectorContainer !ys) -> cosineSim xs ys
        originalSample = VU.fromList . fmap fromIntegral $ [0..size - 1]
        toVec (IntMapContainer xs) = (imapToVec (Size size) 0 $ xs) :: VU.Vector Double
        toVec (VectorContainer xs) = VU.convert xs
        xsYSVec        = VU.zip (toVec xs) . toVec $ ys
        bootstrapFunc :: Sample -> Double
        bootstrapFunc = (\x -> if isNaN x then 0 else x) -- Convert NaN values to 0. Whether this should be done or not is a matter of opinion.
                      . cosineSimVec
                      . VU.map (\x -> xsYSVec VU.! truncate x)

    g <- createSystemRandom

    randomSamples <- resample g [Function bootstrapFunc] nPerm originalSample

    let bootstrap = head
                    . bootstrapBCA
                        0.95
                        originalSample
                        [Function bootstrapFunc]
                    $ randomSamples

    return (obs, Just . Bootstrap $ bootstrap)

-- | Get the cosine similarity and the subsampling using the edge distribution
-- from the second network (out of service right now).
cosineSubsampleBoot
    :: Permutations
    -> Size
    -> IMap.IntMap Double
    -> IMap.IntMap Double
    -> IO (Double, Maybe Statistic)
cosineSubsampleBoot (Permutations nPerm) (Size size) xs ys = do
    let obs               = cosineSimIMap xs ys
        originalSample    = VU.fromList . fmap fromIntegral $ [0..size - 1]
        bootstrapFunc :: Sample -> Double
        bootstrapFunc idx =
            cosineSimIMap (subsetIMap idxList xs) . subsetIMap idxList $ ys
          where
            idxList = fmap truncate . VU.toList $ idx

    g <- createSystemRandom

    randomSamples <- resample g [Function bootstrapFunc] nPerm originalSample

    let allSame = Estimate { estPoint           = obs
                           , estLowerBound      = obs
                           , estUpperBound      = obs
                           , estConfidenceLevel = 0.95
                           }

    if all (== head randomSamples) randomSamples
        then return (obs, Just . Bootstrap $ allSame)
        else do
            let bootstrap =
                  head
                    . bootstrapBCA 0.95 originalSample [Function bootstrapFunc]
                    $ randomSamples

            return (obs, Just . Bootstrap $ bootstrap)

-- | Get the cosine similarity and the subsampling using the edge distribution
-- from the second network (out of service right now).
cosineOldBoot
    :: Permutations
    -> Size
    -> IMap.IntMap Double
    -> IMap.IntMap Double
    -> IO (Double, Maybe Statistic)
cosineOldBoot (Permutations nPerm) (Size size) xs ys = do
    let obs               = cosineSimIMap xs ys
        originalSample    = VU.fromList . fmap fromIntegral $ [0..size - 1]
        bootstrapFunc :: Sample -> Double
        bootstrapFunc idx =
            cosineSimIMap (subsetIMap idxList xs) . subsetIMap idxList $ ys
          where
            idxList = fmap truncate . VU.toList $ idx

    g <- createSystemRandom

    randomSamples <- resample g [Function bootstrapFunc] nPerm originalSample

    let allSame = Estimate { estPoint           = obs
                           , estLowerBound      = obs
                           , estUpperBound      = obs
                           , estConfidenceLevel = 0.95
                           }

    if all (== head randomSamples) randomSamples
        then return (obs, Just . Bootstrap $ allSame)
        else do
            let bootstrap =
                  head
                    . bootstrapBCA 0.95 originalSample [Function bootstrapFunc]
                    $ randomSamples

            return (obs, Just . Bootstrap $ bootstrap)

-- | Random sample cosine.
randomCosine :: EdgeValues
             -> IMap.IntMap Double
             -> IMap.IntMap Double
             -> IO Double
randomCosine (EdgeValues edgeVals) xs ys = do
    shuffledYS <- getSampleMap edgeVals ys

    return . cosineSimIMap xs $ shuffledYS

-- | Sample map values from the complete set of values.
getSampleMap :: (VG.Vector v a) => v a -> IMap.IntMap a -> IO (IMap.IntMap a)
getSampleMap vals m = do
    let keys = IMap.keys m
        len = VG.length vals - 1

    newIdxs <- sample . replicateM (IMap.size m) . uniform 0 $ len

    return . IMap.fromList . zip keys . fmap (vals VG.!) $ newIdxs

-- | Random shuffle cosine.
shuffleCosine :: IMap.IntMap Double
              -> IMap.IntMap Double
              -> IO Double
shuffleCosine xs ys = do
    shuffledYS <- shuffleMap ys

    return . cosineSimIMap xs $ shuffledYS

-- | Shuffle map keys.
shuffleMap :: IMap.IntMap a -> IO (IMap.IntMap a)
shuffleMap m = do
    let (keys, elems) = unzip . IMap.toList $ m

    newKeys <- sample . shuffle $ keys

    return . IMap.fromList . zip newKeys $ elems
