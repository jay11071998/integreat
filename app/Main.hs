{- integrate
Gregory W. Schwartz

Integrate data from multiple sources to find consistent (or inconsistent)
entities.
-}

{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

-- Standard
import Data.Maybe
import qualified Data.Set as Set
import qualified Data.Map.Strict as Map
import Data.Monoid
import System.IO
import Control.Monad
import Debug.Trace

-- Cabal
import qualified Data.Vector as V
import qualified Data.ByteString.Lazy.Char8 as CL
import qualified Data.Text as T
import qualified Data.Text.IO as T
import qualified Data.Csv as CSV
import qualified Control.Lens as L
import Options.Generic

-- Local
import Types
import Utility
import Load
import NetworkGeneration
import RandomWalk
import Integrate
import Print

-- | Command line arguments
data Options = Options { dataInput     :: String
                                      <?> "(FILE) The input file containing the data intensities. Follows the format: dataLevel,dataReplicate,vertex,intensity. dataLevel is the level (the base level for the experiment, like \"proteomic_Myla\" or \"RNA_MyLa\" for instance), dataReplicate is the replicate in that experiment that the entity is from (the name of that data set with the replicate name, like \"RNA_MyLa_1\"), and vertex is the name of the entity (must match those in the vertex-input), and the intensity is the value of this entity in this data set."
                       , vertexInput   :: Maybe String
                                      <?> "(FILE) The input file containing similarities between entities. Follows the format: vertexLevel1,vertexLevel2, vertex1,vertex2,similarity. vertexLevel1 is the level (the base title for the experiment, \"data set\") that vertex1 is from, vertexLevel2 is the level that vertex2 is from, and the similarity is a number representing the similarity between those two entities. If not specified, then the same entity (determined by vertex in data-input) will have a similarity of 1, different entities will have a similarity of 0."
                       , entityDiff  :: Maybe T.Text
                                    <?> "When comparing entities that are the same, ignore the text after this separator. Used for comparing phosphorylated positions with another level. For example, if we have a strings ARG29 and ARG29_7 that we want to compare, we want to say that their value is the highest in correlation, so this string would be \"_\""
                       , method        :: Maybe String
                                      <?> "([CosineSimilarity] | RandomWalker) The method to get integrated vertex similarity between  levels. CosineSimilarity uses the cosine similarity of each  vertex in each network compared to the other vertices in  other networks. RandomWalker uses a random walker based  network alignment algorithm in order to get similarity."
                       , walkerRestart :: Maybe Double
                                      <?> "([0.05] | PROBABILITY) For the random walker algorithm, the probability of making  a jump to a random vertex. Recommended to be the ratio of  the total number of vertices in the top 99% smallest  subnetworks to the total number of nodes in the reduced  product graph (Jeong, 2015)."
                       , steps         :: Maybe Int
                                      <?> "([10000] | STEPS) For the random walker algorithm, the number of steps to take  before stopping."
                       }
               deriving (Generic)

instance ParseRecord Options

main :: IO ()
main = do
    opts <- getRecord "integrate, Gregory W. Schwartz\
                      \ Integrate data from multiple sources to find consistent\
                      \ (or inconsistent) entities."

    let processCsv = snd . either error id

    dataEntries   <- fmap (processCsv . CSV.decodeByName)
                   . CL.readFile
                   . unHelpful
                   . dataInput
                   $ opts

    let levels       =
            entitiesToLevels . datasToEntities . V.toList $ dataEntries
        unifiedData  = unifyAllLevels . fmap snd $ levels
        levelNames   = Set.toList . Set.fromList . fmap fst $ levels
        idMap        = getIDMap unifiedData
        idVec        = getIDVec unifiedData
        eDiff        = fmap EntityDiff . unHelpful . entityDiff $ opts

    let vertexContents =
            fmap (fmap (processCsv . CSV.decodeByName) . CL.readFile)
                . unHelpful
                . vertexInput
                $ opts
    vertexSimMap <- maybe
                        (return . defVertexSimMap idMap $ levelNames)
                        (fmap (vertexCsvToLevels idMap . V.toList))
                        vertexContents

    let edgeSimMap = EdgeSimMap
                   . Map.fromList
                   . fmap ( L.over L._2 ( getSimMat
                                         (Default (-5))
                                         eDiff
                                         (MaximumEdge 1)
                                         idMap
                                        . standardizeLevel idMap
                                        )
                          )
                   $ levels

    nodeCorrScores <- integrate
                        ( maybe CosineSimilarity read
                        . unHelpful
                        . method
                        $ opts
                        )
                        vertexSimMap
                        edgeSimMap
                        ( WalkerRestart
                        . fromMaybe 0.05
                        . unHelpful
                        . walkerRestart
                        $ opts
                        )
                        (Counter . fromMaybe 10000 . unHelpful . steps $ opts)

    T.putStr . printNodeCorrScores idVec $ nodeCorrScores

    return ()
