{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeOperators #-}

-- |
-- Copyright: © 2018-2019 IOHK
-- License: MIT
--
-- Here we find the "business logic" to manage a Cardano wallet. This is a
-- direct implementation of the model from the [Formal Specification for a Cardano Wallet](https://github.com/input-output-hk/cardano-wallet/blob/master/specifications/wallet/formal-specification-for-a-cardano-wallet.pdf)
-- Note that, this module is purposedly agnostic to how blocks are retrieved or
-- how various types are serialized.
--
-- This is really about how the wallet keep track of its internal state, and its
-- UTxO (where the relationship is defined via the 'IsOurs' abstraction to allow
-- this core code to be used with any sort of derivation scheme).
--
-- All those functions are pure and there's no reason to shove in any sort of
-- side-effects in here :)

module Cardano.Wallet
    (
    -- * Wallet
      Wallet
    , initWallet
    , applyBlock
    , availableBalance
    , totalBalance
    , totalUTxO
    , availableUTxO

    -- * Helpers
    , invariant
    , txOutsOurs
    , utxoFromTx
    ) where

import Prelude

import Cardano.Wallet.Binary
    ( txId )
import Cardano.Wallet.Primitive
    ( Block (..)
    , Dom (..)
    , IsOurs (..)
    , Tx (..)
    , TxIn (..)
    , TxOut (..)
    , UTxO (..)
    , balance
    , excluding
    , restrictedBy
    , restrictedTo
    , txIns
    , updatePending
    )
import Control.DeepSeq
    ( NFData (..), deepseq )
import Control.Monad.Trans.State.Strict
    ( State, runState, state )
import Data.List.NonEmpty
    ( NonEmpty (..) )
import Data.Maybe
    ( catMaybes )
import Data.Set
    ( Set )
import Data.Traversable
    ( for )

import qualified Data.Map as Map
import qualified Data.Set as Set


-- * Wallet

-- | An opaque wallet type, see @initWallet@ and @applyBlock@ to construct and
-- update wallets.
--
-- Internally, this keeps track or a few things including:
--
--  - UTxOs
--  - Pending transaction
--  - TODO: Transaction history
--  - TODO: Known & used addresses
data Wallet s where
    Wallet
        :: (IsOurs s, Semigroup s, NFData s, Show s)
        => UTxO
        -> Set Tx
        -> s
        -> Wallet s

deriving instance Show (Wallet s)

instance NFData (Wallet s) where
    rnf (Wallet utxo pending s) =
        rnf utxo `deepseq` (rnf pending `deepseq` (rnf s `deepseq` ()))


-- | Create an empty wallet from an initial state
initWallet
    :: (IsOurs s, Semigroup s, NFData s, Show s)
    => s
    -> Wallet s
initWallet = Wallet mempty mempty


-- | Apply Block is the only way to make the wallet evolve.
applyBlock
    :: Block
    -> NonEmpty (Wallet s)
    -> NonEmpty (Wallet s)
applyBlock !b (cp@(Wallet !utxo !pending _) :| checkpoints) =
    let
        (ourUtxo, ourIns, s') = prefilterBlock b cp
        utxo' = (utxo <> ourUtxo) `excluding` ourIns
        pending' = updatePending b pending
        cp' = Wallet utxo' pending' s'
    in
        -- NOTE
        -- k = 2160 is currently hard-coded here. In the short-long run, we do
        -- want to get that as an argument or, leave that decision to the caller
        -- though it is not trivial at all. If it shrinks, it's okay because we
        -- have enough checkpoints, but if it does increase, then we have
        -- problems in case of rollbacks.
        (cp' :| cp : take 2160 checkpoints)


-- | Available balance = 'balance' . 'availableUTxO'
availableBalance :: Wallet s -> Integer
availableBalance =
    balance . availableUTxO


-- | Total balance = 'balance' . 'totalUTxO'
totalBalance :: Wallet s -> Integer
totalBalance =
    balance . totalUTxO


-- | Available UTxO = UTxO that aren't part of pending txs
availableUTxO :: Wallet s -> UTxO
availableUTxO (Wallet utxo pending _) =
    utxo `excluding` txIns pending


-- | Total UTxO = 'availableUTxO' <> "pending UTxO"
totalUTxO :: Wallet s -> UTxO
totalUTxO wallet@(Wallet _ pending s) =
    let
        -- NOTE
        -- We _safely_ discard the state here because we aren't intending to
        -- discover any new addresses through this operation. In practice, we
        -- can only discover new addresses when applying blocks.
        discardState = fst
    in
        availableUTxO wallet <> discardState (changeUTxO pending s)


-- * Helpers

-- | Check whether an invariants holds or not.
--
-- >>> invariant "not empty" [1,2,3] (not . null)
-- [1, 2, 3]
--
-- >>> invariant "not empty" [] (not . null)
-- *** Exception: not empty
invariant
    :: String -- ^ A title / message to throw in case of violation
    -> a
    -> (a -> Bool)
    -> a
invariant msg a predicate =
    if predicate a then a else error msg

-- | Return all transaction outputs that are ours. This plays well within a
-- 'State' monad.
--
-- @
-- myFunction :: Block -> State s Result
-- myFunction b = do
--    ours <- state $ txOutsOurs (transaction b)
--    return $ someComputation ours
-- @
txOutsOurs
    :: forall s. (IsOurs s)
    => Set Tx
    -> s
    -> (Set TxOut, s)
txOutsOurs txs =
    runState $ Set.fromList <$> forMaybe (foldMap outputs txs) pick
  where
    pick :: TxOut -> State s (Maybe TxOut)
    pick out = do
        predicate <- state $ isOurs (address out)
        return $ if predicate then Just out else Nothing

    forMaybe :: Monad m => [a] -> (a -> m (Maybe b)) -> m [b]
    forMaybe xs = fmap catMaybes . for xs

-- | Construct a UTxO corresponding to a given transaction. It is important for
-- the transaction outputs to be ordered correctly, since they become available
-- inputs for the subsequent blocks.
utxoFromTx :: Tx -> UTxO
utxoFromTx tx@(Tx _ outs) =
    UTxO $ Map.fromList $ zip (TxIn (txId tx) <$> [0..]) outs


-- * Internals

prefilterBlock
    :: Block
    -> Wallet s
    -> (UTxO, Set TxIn, s)
prefilterBlock b (Wallet !utxo _ !s) =
    let
        txs = transactions b
        (ourOuts, s') = txOutsOurs txs s
        ourUtxo = foldMap utxoFromTx txs `restrictedTo` ourOuts
        ourIns = txIns txs `Set.intersection` dom (utxo <> ourUtxo)
    in
        invariant "applyBlock requires: dom ourUtxo ∩ dom utxo = ∅"
            (ourUtxo, ourIns, s')
            (const $ Set.null $ dom ourUtxo `Set.intersection` dom utxo)

changeUTxO
    :: IsOurs s
    => Set Tx
    -> s
    -> (UTxO, s)
changeUTxO pending = runState $ do
    ours <- state $ txOutsOurs pending
    let utxo = foldMap utxoFromTx pending
    let ins = txIns pending
    return $ (utxo `restrictedTo` ours) `restrictedBy` ins
