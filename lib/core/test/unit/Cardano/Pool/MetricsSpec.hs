{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}

module Cardano.Pool.MetricsSpec
    ( spec
    , arbitraryChunks
    , RegistrationsTest
    ) where

import Prelude

import Cardano.Pool.DB
    ( DBLayer (..) )
import Cardano.Pool.DB.MVar
    ( newDBLayer )
import Cardano.Pool.Metrics
    ( Block (..), calculatePerformance, combineMetrics, monitorStakePools )
import Cardano.Wallet.DummyTarget.Primitive.Types
    ( genesisParameters )
import Cardano.Wallet.Network
    ( Cursor
    , ErrGetBlock (..)
    , ErrNetworkUnavailable (..)
    , NetworkLayer (..)
    , NextBlocksResult (..)
    )
import Cardano.Wallet.Primitive.Model
    ( BlockchainParameters (..), slotParams )
import Cardano.Wallet.Primitive.Types
    ( BlockHeader (..)
    , Coin (..)
    , EpochLength (..)
    , Hash (..)
    , PoolId (..)
    , PoolOwner (..)
    , PoolRegistrationCertificate (..)
    , SlotId (..)
    , flatSlot
    , flatSlot
    , fromFlatSlot
    , slotSucc
    )
import Control.Concurrent.Async
    ( race_ )
import Control.Concurrent.MVar
    ( MVar, modifyMVar, newEmptyMVar, newMVar, takeMVar, tryPutMVar )
import Control.Monad
    ( replicateM )
import Control.Monad.Trans.Class
    ( lift )
import Control.Monad.Trans.Except
    ( ExceptT (..) )
import Control.Monad.Trans.State.Strict
    ( StateT, evalStateT, get, modify' )
import Data.Function
    ( (&) )
import Data.Functor
    ( ($>) )
import Data.Map.Strict
    ( Map )
import Data.Quantity
    ( Quantity (..) )
import Data.Set
    ( Set )
import Data.Text
    ( Text )
import Data.Text.Class
    ( toText )
import Data.Word
    ( Word32, Word64 )
import Test.Hspec
    ( Spec, describe, it, shouldBe )
import Test.QuickCheck
    ( Arbitrary (..)
    , Gen
    , NonEmptyList (..)
    , NonNegative (..)
    , Positive (..)
    , Property
    , checkCoverage
    , choose
    , classify
    , counterexample
    , cover
    , elements
    , frequency
    , property
    , scale
    , vectorOf
    , (===)
    )
import Test.QuickCheck.Arbitrary.Generic
    ( genericArbitrary, genericShrink )
import Test.QuickCheck.Monadic
    ( assert, monadicIO, monitor, run )
import Test.Utils.Trace
    ( captureLogging )

import qualified Data.ByteString.Char8 as B8
import qualified Data.List as L
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as T

spec :: Spec
spec = do
    describe "combineMetrics" $ do
        it "pools with no entry for productions are included"
            $ property prop_combineDefaults

        it "it fails if a block-producer is not in the stake distr"
            $ checkCoverage
            $ property prop_combineIsLeftBiased

    describe "calculatePerformances" $ do
        it "performances are always between 0 and 1"
            $ property prop_performancesBounded01

        describe "golden test cases" $ do
            performanceGoldens

    describe "monitorStakePools" $ do
        it "records all stake pool registrations in the database"
            $ property prop_trackRegistrations

{-------------------------------------------------------------------------------
                                Properties
-------------------------------------------------------------------------------}

prop_combineDefaults
    :: Map PoolId (Quantity "lovelace" Word64)
    -> Property
prop_combineDefaults mStake = do
    combineMetrics mStake Map.empty Map.empty
    ===
    Right (Map.map (, Quantity 0, 0) mStake)

-- | it fails if a block-producer or performance is not in the stake distr
prop_combineIsLeftBiased
    :: Map PoolId (Quantity "lovelace" Word64)
    -> Map PoolId (Quantity "block" Word64)
    -> Map PoolId Double
    -> Property
prop_combineIsLeftBiased mStake mProd mPerf =
    let
        shouldLeft = or
            [ not . Map.null $ Map.difference mProd mStake
            , not . Map.null $ Map.difference mPerf mStake
            ]
    in
    cover 10 shouldLeft "A pool without stake produced"
    $ cover 50 (not shouldLeft) "Successfully combined the maps"
    $ case combineMetrics mStake mProd mPerf of
        Left _ ->
            shouldLeft === True
        Right x ->
            Map.map (\(a,_,_) -> a) x === mStake
{-# HLINT ignore prop_combineIsLeftBiased "Use ||" #-}

-- | Performances are always positive numbers
prop_performancesBounded01
    :: Map PoolId (Quantity "lovelace" Word64)
    -> Map PoolId (Quantity "block" Word64)
    -> (NonNegative Int)
    -> Property
prop_performancesBounded01 mStake mProd (NonNegative emptySlots) =
    all (between 0 1) performances
    & counterexample (show performances)
    & classify (all (== 0) performances) "all null"
  where
    performances :: [Double]
    performances = Map.elems $ calculatePerformance slots mStake mProd

    slots :: Int
    slots = emptySlots +
        fromIntegral (Map.foldl (\y (Quantity x) -> (y + x)) 0 mProd)

    between :: Ord a => a -> a -> a -> Bool
    between inf sup x = x >= inf && x <= sup


performanceGoldens :: Spec
performanceGoldens = do
    it "50% stake, producing 8/8 blocks => performance=1.0" $ do
        let stake      = mkStake      [ (poolA, 1), (poolB, 1) ]
        let production = mkProduction [ (poolA, 8), (poolB, 0) ]
        let performances = calculatePerformance 8 stake production
        Map.lookup poolA performances `shouldBe` (Just 1)

    it "50% stake, producing 4/8 blocks => performance=1.0" $ do
        let stake      = mkStake      [ (poolA, 1), (poolB, 1) ]
        let production = mkProduction [ (poolA, 4), (poolB, 0) ]
        let performances = calculatePerformance 8 stake production
        Map.lookup poolA performances `shouldBe` (Just 1)

    it "50% stake, producing 2/8 blocks => performance=0.5" $ do
        let stake      = mkStake      [ (poolA, 1), (poolB, 1) ]
        let production = mkProduction [ (poolA, 2), (poolB, 0) ]
        let performances = calculatePerformance 8 stake production
        Map.lookup poolA performances `shouldBe` (Just 0.5)

    it "50% stake, producing 0/8 blocks => performance=0.0" $ do
        let stake      = mkStake      [ (poolA, 1), (poolB, 1) ]
        let production = mkProduction [ (poolA, 0), (poolB, 0) ]
        let performances = calculatePerformance 8 stake production
        Map.lookup poolA performances `shouldBe` (Just 0)
  where
    poolA = PoolId "athena"
    poolB = PoolId "nemesis"
    mkStake = Map.map Quantity . Map.fromList
    mkProduction = Map.map Quantity . Map.fromList

-- | A list of chunks of blocks to be served up by the mock network layer.
newtype RegistrationsTest = RegistrationsTest
    { getRegistrationsTest :: [[Block]] }
    deriving (Show, Eq)

-- | Assert that 'monitorStakePools' records all stake pool registrations in the
-- database.
--
-- The idea is to run 'monitorStakePools' with an in-memory database and mock
-- network layer.
--
-- The mock network layer serves up chunks of blocks from the testcase, which
-- contain registration certificates
--
-- It then asserts that the registration info in the database matches that of
-- the blocks of the test case.
prop_trackRegistrations :: RegistrationsTest -> Property
prop_trackRegistrations test = monadicIO $ do
    let expected = getExpected test
    let numRegistrations = getNumRegistrations test

    (logs, ownership) <- run $ captureLogging $ \tr -> do
        done <- newEmptyMVar
        nl <- newMockNetworkLayer done test
        db@DBLayer{..} <- newDBLayer
        race_ (takeMVar done) (monitorStakePools tr nl db)

        let pids = Map.keys expected
        owners <- atomically $ mapM readStakePoolOwners pids
        pure $ Map.fromList $ zip pids (L.sort <$> owners)

    let numDiscoveryLogs = length (filter isDiscoveryMsg logs)

    monitor $ counterexample $ "Actual pool owners:   " <> show ownership
    monitor $ counterexample $ "Expected pool owners: " <> show expected
    monitor $ counterexample $ "# Discovery log msgs: " <> show numDiscoveryLogs
    monitor $ counterexample $ "# Registration certs: " <> show numRegistrations
    monitor $ counterexample $ "Logs:\n" <>
        unlines (map (("  " ++) . T.unpack . toText) logs)

    assert (ownership == expected)
    assert (numDiscoveryLogs == numRegistrations)
  where
    getExpected :: RegistrationsTest -> Map PoolId [PoolOwner]
    getExpected =
        Map.map (L.sort . Set.toList)
        . L.foldl' merge mempty
        . mconcat
        . getRegistrationsTest
      where
        merge
            :: Map PoolId (Set PoolOwner)
            -> Block
            -> Map PoolId (Set PoolOwner)
        merge m blk = Map.unionsWith (<>) $ m : (fromCert <$> poolRegistrations blk)
          where
            fromCert (PoolRegistrationCertificate pid owners) =
                Map.singleton pid (Set.fromList owners)

    isDiscoveryMsg :: Text -> Bool
    isDiscoveryMsg = T.isInfixOf "Discovered stake pool registration"

    getNumRegistrations :: RegistrationsTest -> Int
    getNumRegistrations =
        sum
        . map (sum . map (length . poolRegistrations))
        . getRegistrationsTest

    newMockNetworkLayer
        :: MVar ()
        -> RegistrationsTest
        -> IO (NetworkLayer IO RegistrationsTest Block)
    newMockNetworkLayer done (RegistrationsTest blocks) = do
        blockVar <- newMVar blocks
        let popChunk = modifyMVar blockVar $ \case
                [] -> pure ([], Nothing)
                (b:bs) -> pure (bs, Just b)
        pure $ mockNetworkLayer
            { nextBlocks = \cursor@(Cursor blkH) -> ExceptT $ popChunk >>= \case
                    Just bs -> pure
                        $ Right
                        $ RollForward cursor blkH bs
                    Nothing -> do
                        tryPutMVar done () $> (Left
                            $ ErrGetBlockNetworkUnreachable
                            $ ErrNetworkInvalid "The test case has finished")
            , initCursor =
                const $ Cursor header0
            , stakeDistribution =
                pure (0, mempty)
            , networkTip =
                pure header0
            -- These params are basically unused and completely arbitrary.
            , staticBlockchainParameters =
                (block0, mockBlockchainParameters
                    { getEpochStability = Quantity 2 })
            }

data instance Cursor RegistrationsTest = Cursor BlockHeader

{-------------------------------------------------------------------------------
                                 Mock Data
-------------------------------------------------------------------------------}

-- A mock network layer placeholder that can be re-used across tests. Functions
-- required by a particular test can be stubbed out or mocked as necessary.
mockNetworkLayer :: NetworkLayer m t b
mockNetworkLayer = NetworkLayer
    { nextBlocks =
        \_ -> error "mockNetworkLayer: nextBlocks"
    , findIntersection =
        \_ -> error "mockNetworkLayer: findIntersection"
    , initCursor =
        \_ -> error "mockNetworkLayer: initCursor"
    , cursorSlotId =
        \_ -> error "mockNetworkLayer: cursorSlotId"
    , networkTip =
        error "mockNetworkLayer: networkTip"
    , postTx =
        \_ -> error "mockNetworkLayer: postTx"
    , staticBlockchainParameters =
        ( error "mockNetworkLayer: genesis block"
        , mockBlockchainParameters )
    , stakeDistribution =
        error "mockNetworkLayer: stakeDistribution"
    , getAccountBalance =
        \_ -> error "mockNetworkLayer: getAccountBalance"
    }

mockBlockchainParameters :: BlockchainParameters
mockBlockchainParameters = BlockchainParameters
    { getGenesisBlockHash = error "mockBlockchainParameters: getGenesisBlockHash"
    , getGenesisBlockDate = error "mockBlockchainParameters: getGenesisBlockDate"
    , getFeePolicy = error "mockBlockchainParameters: getFeePolicy"
    , getSlotLength = error "mockBlockchainParameters: getSlotLength"
    , getEpochLength = error "mockBlockchainParameters: getEpochLength"
    , getTxMaxSize = error "mockBlockchainParameters: getTxMaxSize"
    , getEpochStability = error "mockBlockchainParameters: getEpochStability"
    }

header0 :: BlockHeader
header0 = BlockHeader
    (SlotId 0 0)
    (Quantity 0)
    (Hash $ B8.replicate 32 '0')
    (Hash $ B8.replicate 32 '0')

block0 :: Block
block0 = Block header0 (PoolId "") []

{-------------------------------------------------------------------------------
                                 Arbitrary
-------------------------------------------------------------------------------}

instance Arbitrary BlockHeader where
    arbitrary = BlockHeader
        <$> arbitrary
        <*> arbitrary
        <*> arbitrary
        <*> arbitrary
    shrink = genericShrink

instance Arbitrary SlotId where
    arbitrary = fromFlatSlot epochLength <$> arbitrary
    shrink sl = fromFlatSlot epochLength <$> shrink (flatSlot epochLength sl)

-- | Epoch length used to generate arbitrary @SlotId@
epochLength :: EpochLength
epochLength = EpochLength 50

instance Arbitrary (Hash tag) where
    shrink _  = []
    arbitrary = Hash . B8.pack
        <$> vectorOf 32 (elements (['a'..'f'] ++ ['0'..'9']))

instance Arbitrary Block where
   arbitrary = genericArbitrary
   shrink = genericShrink

instance Arbitrary (Quantity "block" Word32) where
    arbitrary = Quantity . fromIntegral <$> (arbitrary @Word32)
    shrink (Quantity x) = map Quantity $ shrink x

instance Arbitrary (Quantity "block" Word64) where
    arbitrary = Quantity . fromIntegral <$> (arbitrary @Word32)
    shrink (Quantity x) = map Quantity $ shrink x

instance Arbitrary (Quantity "lovelace" Word64) where
    arbitrary = Quantity . fromIntegral . unLovelace <$> (arbitrary @Lovelace)
    shrink (Quantity x) = map Quantity $ shrink x

-- TODO: Move to a shared location for Arbitrary newtypes
newtype Lovelace = Lovelace { unLovelace :: Word64 }
instance Arbitrary Lovelace where
    shrink (Lovelace x) = map Lovelace $ shrink x
    arbitrary = do
        n <- choose (0, 100)
        Lovelace <$> frequency
            [ (8, return n)
            , (2, choose (minLovelace, maxLovelace))
            ]
      where
        minLovelace = fromIntegral . getCoin $ minBound @Coin
        maxLovelace = fromIntegral . getCoin $ maxBound @Coin

instance Arbitrary PoolId where
    shrink _  = []
    arbitrary = PoolId . B8.pack
        <$> elements [ "ares", "athena", "hades", "hestia", "nemesis" ]

instance Arbitrary PoolOwner where
    shrink _  = []
    arbitrary = PoolOwner . B8.singleton <$> elements ['a'..'e']

instance Arbitrary PoolRegistrationCertificate where
    shrink (PoolRegistrationCertificate p o) =
        (\(p', NonEmpty o') -> PoolRegistrationCertificate p' o')
        <$> shrink (p, NonEmpty o)
    arbitrary = PoolRegistrationCertificate
        <$> arbitrary
        <*> fmap getNonEmpty (scale (`mod` 3) arbitrary)

instance Arbitrary RegistrationsTest where
    shrink (RegistrationsTest xs) = RegistrationsTest <$> shrink xs
    arbitrary = do
        Positive n <- arbitrary
        chunks <- arbitraryChunks =<< evalStateT (replicateM n genBlock) state0
        pure $ RegistrationsTest chunks
      where
        state0 :: (Hash "BlockHeader", SlotId)
        state0 = (headerHash header0, slotId header0)

        genBlock :: StateT (Hash "BlockHeader", SlotId) Gen Block
        genBlock = Block
            <$> genBlockHeader
            <*> lift arbitrary
            <*> lift arbitrary

        genBlockHeader :: StateT (Hash "BlockHeader", SlotId) Gen BlockHeader
        genBlockHeader = do
            (parentHeaderHash, _) <- get
            (headerHash, slotId) <- nextState
            let blockHeight = Quantity $ fromIntegral $ flatSlot ep slotId
            pure BlockHeader
                { slotId
                , blockHeight
                , headerHash
                , parentHeaderHash
                }
          where
            ep = getEpochLength genesisParameters

        nextState :: (s ~ (Hash "BlockHeader", SlotId)) => StateT s Gen s
        nextState = do
            nextHeaderHash <- lift arbitrary
            modify' (\(_, sl) -> (nextHeaderHash, slotSucc sp sl)) >> get
          where
            sp = slotParams genesisParameters

arbitraryChunks :: [a] -> Gen [[a]]
arbitraryChunks [] = pure []
arbitraryChunks xs = do
    n <- choose (1, length xs)
    rest <- arbitraryChunks (drop n xs)
    pure $ take n xs : rest
