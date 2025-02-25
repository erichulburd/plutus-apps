{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE DeriveAnyClass      #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE DerivingStrategies  #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE TypeFamilies        #-}
{-# OPTIONS_GHC -fno-ignore-interface-pragmas #-}
-- | A "pay-to-pubkey" transaction output implemented as a Plutus
--   contract. This is useful if you need something that behaves like
--   a pay-to-pubkey output, but is not (easily) identified by wallets
--   as one.
module Plutus.Contracts.PubKey(pubKeyContract, typedValidator, PubKeyError(..), AsPubKeyError(..)) where

import Control.Lens
import Control.Monad (void)
import Control.Monad.Error.Lens
import Data.Aeson (FromJSON, ToJSON)
import Data.Map qualified as Map
import GHC.Generics (Generic)

import Ledger hiding (initialise, to)
import Ledger.Typed.Scripts (TypedValidator)
import Ledger.Typed.Scripts qualified as Scripts
import Plutus.V1.Ledger.Contexts as V
import PlutusTx qualified

import Ledger.Constraints qualified as Constraints
import Plutus.ChainIndex.Types (Tip (Tip, TipAtGenesis))
import Plutus.Contract as Contract

mkValidator :: PaymentPubKeyHash -> () -> () -> ScriptContext -> Bool
mkValidator pk' _ _ p = V.txSignedBy (scriptContextTxInfo p) (unPaymentPubKeyHash pk')

data PubKeyContract

instance Scripts.ValidatorTypes PubKeyContract where
    type instance RedeemerType PubKeyContract = ()
    type instance DatumType PubKeyContract = ()

typedValidator :: PaymentPubKeyHash -> Scripts.TypedValidator PubKeyContract
typedValidator = Scripts.mkTypedValidatorParam @PubKeyContract
    $$(PlutusTx.compile [|| mkValidator ||])
    $$(PlutusTx.compile [|| wrap ||])
    where
        wrap = Scripts.mkUntypedValidator

data PubKeyError =
    ScriptOutputMissing PaymentPubKeyHash
    | MultipleScriptOutputs PaymentPubKeyHash
    | PKContractError ContractError
    deriving stock (Eq, Show, Generic)
    deriving anyclass (ToJSON, FromJSON)

makeClassyPrisms ''PubKeyError

instance AsContractError PubKeyError where
    _ContractError = _PKContractError

-- | Lock some funds in a 'PayToPubKey' contract, returning the output's address
--   and a 'TxIn' transaction input that can spend it.
pubKeyContract
    :: forall w s e.
    ( AsPubKeyError e
    )
    => PaymentPubKeyHash
    -> Value
    -> Contract w s e (TxOutRef, Maybe ChainIndexTxOut, TypedValidator PubKeyContract)
pubKeyContract pk vl = mapError (review _PubKeyError   ) $ do
    let inst = typedValidator pk
        address = Scripts.validatorAddress inst
        tx = Constraints.mustPayToTheScript () vl

    ledgerTx <- mkTxConstraints (Constraints.typedValidatorLookups inst) tx
        >>= adjustUnbalancedTx >>= submitUnbalancedTx

    _ <- awaitTxConfirmed (getCardanoTxId ledgerTx)
    let refs = Map.keys
               $ Map.filter ((==) address . txOutAddress)
               $ getCardanoTxUnspentOutputsTx ledgerTx

    case refs of
        []                   -> throwing _ScriptOutputMissing pk
        [outRef] -> do
            -- TODO: THE FOLLOWING SHOULD BE REMOVED EVENTUALLY.
            -- Currently, the PAB indexes information about the status of
            -- transaction outputs. However, even if the transaction is
            -- confirmed, it might take some time in order for the chain-index
            -- to update it's database with the new confirmed transaction.
            -- Ultimately, the solution is to move indexed information by the
            -- PAB to the chain-index, so that we get a single source of truth.
            --
            -- The temporary solution is to use the 'awaitChainIndexSlot' call
            -- which waits until the chain-index is up to date. Meaning, the
            -- chain-index's synced slot should be at least as high as the
            -- current slot.
            --
            -- See https://plutus-apps.readthedocs.io/en/latest/adr/0002-pab-indexing-solution-integration.html"
            -- for the full explanation.
            --
            -- The 'awaitChainIndexSlot' blocks the contract until the chain-index
            -- is synced until the current slot. This is not a good solution,
            -- as the chain-index is always some time behind the current slot.
            slot <- currentPABSlot
            awaitChainIndexSlot slot

            ciTxOut <- unspentTxOutFromRef outRef
            pure (outRef, ciTxOut, inst)
        _                    -> throwing _MultipleScriptOutputs pk

-- | Temporary. Read TODO in 'pubKeyContract'.
awaitChainIndexSlot :: (AsContractError e) => Slot -> Contract w s e ()
awaitChainIndexSlot targetSlot = do
    chainIndexTip <- getTip
    let chainIndexSlot = getChainIndexSlot chainIndexTip
    if chainIndexSlot < targetSlot
       then do
           void $ waitNSlots 1
           awaitChainIndexSlot targetSlot
       else
           pure ()
 where
    getChainIndexSlot :: Tip -> Slot
    getChainIndexSlot TipAtGenesis   = Slot 0
    getChainIndexSlot (Tip slot _ _) = slot
