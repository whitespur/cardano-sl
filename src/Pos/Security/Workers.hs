{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE UndecidableInstances #-}

module Pos.Security.Workers
       ( SecurityWorkersClass (..)
       ) where

import           Control.Concurrent.STM            (TVar, newTVar, readTVar, writeTVar)
import           Control.Monad.Trans.Reader        (ReaderT (..), ask)
import qualified Data.HashMap.Strict               as HM
import           Data.Tagged                       (Tagged (..))
import           Formatting                        (build, int, sformat, (%))
import           Node                              (SendActions)
import           System.Wlog                       (logError, logWarning)
import           Universum                         hiding (ask)

import           Pos.Block.Network.Retrieval       (requestTip)
import           Pos.Communication.BiP             (BiP)
import           Pos.Constants                     (blkSecurityParam,
                                                    mdNoBlocksSlotThreshold,
                                                    mdNoCommitmentsEpochThreshold)
import           Pos.Context                       (getNodeContext, ncPublicKey)
import           Pos.DB                            (getBlockHeader, getTipBlockHeader,
                                                    loadBlundsFromTipByDepth)
import           Pos.DHT.Model                     (converseToNeighbors)
import           Pos.Security.Class                (SecurityWorkersClass (..))
import           Pos.Slotting                      (onNewSlot)
import           Pos.Ssc.GodTossing.Types.Instance ()
import           Pos.Ssc.GodTossing.Types.Type     (SscGodTossing)
import           Pos.Ssc.GodTossing.Types.Types    (GtPayload (..), SscBi)
import           Pos.Ssc.NistBeacon                (SscNistBeacon)
import           Pos.Types                         (EpochIndex, MainBlock, SlotId (..),
                                                    blockMpc, flattenEpochOrSlot,
                                                    flattenSlotId, genesisHash,
                                                    headerLeaderKey, prevBlockL)
import           Pos.Types.Address                 (addressHash)
import           Pos.WorkMode                      (WorkMode)

instance SscBi => SecurityWorkersClass SscGodTossing where
    securityWorkers = Tagged [ checkForReceivedBlocksWorker
                             , checkForIgnoredCommitmentsWorker
                             ]

instance SecurityWorkersClass SscNistBeacon where
    securityWorkers = Tagged [ checkForReceivedBlocksWorker
                             ]

checkForReceivedBlocksWorker :: WorkMode ssc m => SendActions BiP m -> m ()
checkForReceivedBlocksWorker sendActions = onNewSlot True $ \slotId -> do
    ourPk <- ncPublicKey <$> getNodeContext

    -- If there are no main blocks generated by someone else in the past
    -- 'mdNoBlocksSlotThreshold' slots, it's bad and we've been eclipsed.
    -- Here's how we determine that a block is good (i.e. main block
    -- generated not by us):
    let isGoodBlock (Left _)   = False
        isGoodBlock (Right mb) = mb ^. headerLeaderKey /= ourPk
    -- We stop looking for blocks when we've gone earlier than
    -- 'mdNoBlocksSlotThreshold':
    let pastThreshold header =
            (flattenSlotId slotId - flattenEpochOrSlot header) >
            mdNoBlocksSlotThreshold
    -- Okay, now let's iterate until we see a good blocks or until we go past
    -- the threshold and there's no point in looking anymore:
    let notEclipsed header = do
            let prevBlock = header ^. prevBlockL
                onBlockLoadFailure = logError $ sformat
                    ("no block corresponding to hash "%build) prevBlock
            if | pastThreshold header     -> return False
               | prevBlock == genesisHash -> return True
               | isGoodBlock header       -> return True
               | otherwise                ->
                     getBlockHeader prevBlock >>= \case
                         Just h  -> notEclipsed h
                         Nothing -> do
                             onBlockLoadFailure
                             -- not much point in warning about eclipse
                             -- when we have a much bigger problem
                             -- on our hands (couldn't load a block)
                             return True

    -- Run the iteration starting from tip block; if we have found that we're
    -- eclipsed, we report it and ask neighbors for headers.
    unlessM (notEclipsed =<< getTipBlockHeader) $ do
        logWarning $
            "Our neighbors are likely trying to carry out an eclipse attack! " <>
            "There are no blocks younger " <>
            "than 'mdNoBlocksSlotThreshold' that we didn't generate " <>
            "by ourselves"
        converseToNeighbors sendActions requestTip

checkForIgnoredCommitmentsWorker :: forall m. WorkMode SscGodTossing m => SendActions BiP m -> m ()
checkForIgnoredCommitmentsWorker __sendActions = do
    epochIdx <- atomically (newTVar 0)
    _ <- runReaderT (onNewSlot True checkForIgnoredCommitmentsWorkerImpl) epochIdx
    return ()

checkForIgnoredCommitmentsWorkerImpl
    :: forall m. WorkMode SscGodTossing m
    => SlotId -> ReaderT (TVar EpochIndex) m ()
checkForIgnoredCommitmentsWorkerImpl slotId = do
    checkCommitmentsInPreviousBlocks slotId
    tvar <- ask
    lastCommitment <- lift $ atomically $ readTVar tvar
    when (siEpoch slotId - lastCommitment > mdNoCommitmentsEpochThreshold) $
        logWarning $ sformat
            ("Our neighbors are likely trying to carry out an eclipse attack! "%
             "Last commitment was at epoch "%int%", "%
             "which is more than 'mdNoCommitmentsEpochThreshold' epochs ago")
            lastCommitment

checkCommitmentsInPreviousBlocks
    :: forall m. WorkMode SscGodTossing m
    => SlotId -> ReaderT (TVar EpochIndex) m ()
checkCommitmentsInPreviousBlocks slotId = do
    kBlocks <- map fst <$> loadBlundsFromTipByDepth blkSecurityParam
    forM_ kBlocks $ \case
        Right blk -> checkCommitmentsInBlock slotId blk
        _         -> return ()

checkCommitmentsInBlock
    :: forall m. WorkMode SscGodTossing m
    => SlotId -> MainBlock SscGodTossing -> ReaderT (TVar EpochIndex) m ()
checkCommitmentsInBlock slotId block = do
    ourId <- addressHash . ncPublicKey <$> getNodeContext
    let commitmentInBlockchain = isCommitmentInPayload ourId (block ^. blockMpc)
    when commitmentInBlockchain $ do
        tvar <- ask
        lift $ atomically $ writeTVar tvar $ siEpoch slotId
  where
    isCommitmentInPayload addr (CommitmentsPayload commitments _) = HM.member addr commitments
    isCommitmentInPayload _ _ = False
