pragma solidity ^0.5.15;
pragma experimental ABIEncoderV2;

import {SafeMath} from "@openzeppelin/contracts/math/SafeMath.sol";
import "solidity-bytes-utils/contracts/BytesLib.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {ITokenRegistry} from "./interfaces/ITokenRegistry.sol";
import {IFraudProof} from "./interfaces/IFraudProof.sol";
import {ParamManager} from "./libs/ParamManager.sol";
import {Types} from "./libs/Types.sol";
import {RollupUtils} from "./libs/RollupUtils.sol";
import {ECVerify} from "./libs/ECVerify.sol";
import {Logger} from "./logger.sol";
import {POB} from "./POB.sol";
import {MerkleTreeUtils as MTUtils} from "./MerkleTreeUtils.sol";
import {NameRegistry as Registry} from "./NameRegistry.sol";
import {Governance} from "./Governance.sol";
import {DepositManager} from "./DepositManager.sol";

import {BLS} from "./libs/BLS.sol";
import {BLSAccountRegistry} from "./BLSAccountRegistry.sol";

contract RollupSetup {
    // FIX:
    // These constants are related with transaction encoding and
    // should be fixed with actual size.
    uint256 constant TX_LEN = 16;
    uint256 constant accountIDPosition = 4;
    // TODO: Use commented when bump sol to v0.6
    // uint256 constant accountIDMask = (1 << accountIDPosition * 8) - 1;
    uint256 constant accountIDMask = 0xffff;
    uint256 constant txMask = (1 << TX_LEN) - 1;

    // FIX: use the one from AccountTree.sol
    uint256 constant ACCOUNT_WITNESS_LENGTH = 31;

    using SafeMath for uint256;
    using BytesLib for bytes;
    using ECVerify for bytes32;

    /*********************
     * Variable Declarations *
     ********************/

    // External contracts
    DepositManager public depositManager;
    BLSAccountRegistry public accountRegistry;
    Logger public logger;
    ITokenRegistry public tokenRegistry;
    Registry public nameRegistry;
    Types.Batch[] public batches;
    MTUtils public merkleUtils;

    IFraudProof public fraudProof;

    bytes32
        public constant ZERO_BYTES32 = 0x0000000000000000000000000000000000000000000000000000000000000000;
    address payable constant BURN_ADDRESS = 0x0000000000000000000000000000000000000000;
    Governance public governance;

    // this variable will be greater than 0 if
    // there is rollback in progress
    // will be reset to 0 once rollback is completed
    uint256 public invalidBatchMarker;

    modifier onlyCoordinator() {
        POB pobContract = POB(
            nameRegistry.getContractDetails(ParamManager.POB())
        );
        assert(msg.sender == pobContract.getCoordinator());
        _;
    }

    modifier isNotRollingBack() {
        assert(invalidBatchMarker == 0);
        _;
    }

    modifier isRollingBack() {
        assert(invalidBatchMarker > 0);
        _;
    }
}

contract RollupHelpers is RollupSetup {
    /**
     * @notice Returns the latest state root
     */
    function getLatestBalanceTreeRoot() public view returns (bytes32) {
        return batches[batches.length - 1].stateRoot;
    }

    /**
     * @notice Returns the total number of batches submitted
     */
    function numOfBatchesSubmitted() public view returns (uint256) {
        return batches.length;
    }

    function addNewBatch(
        bytes32 txCommit,
        bytes32 txRoot,
        bytes32 _updatedRoot,
        uint256[2] memory signature
    ) internal {
        Types.Batch memory newBatch = Types.Batch({
            stateRoot: _updatedRoot,
            accountRoot: accountRegistry.root(),
            depositTree: ZERO_BYTES32,
            committer: msg.sender,
            txRoot: txRoot,
            txCommit: txCommit,
            stakeCommitted: msg.value,
            finalisesOn: block.number + governance.TIME_TO_FINALISE(),
            timestamp: now,
            signature: signature
        });

        batches.push(newBatch);
        logger.logNewBatch(
            newBatch.committer,
            txCommit,
            _updatedRoot,
            batches.length - 1
        );
    }

    function addNewBatchWithDeposit(bytes32 _updatedRoot, bytes32 depositRoot)
        internal
    {
        // TODO: use different batch type w/o signature?
        // TODO: txRoot can be used for deposit root
        Types.Batch memory newBatch = Types.Batch({
            stateRoot: _updatedRoot,
            accountRoot: accountRegistry.root(),
            depositTree: depositRoot,
            committer: msg.sender,
            txCommit: ZERO_BYTES32,
            txRoot: depositRoot,
            stakeCommitted: msg.value,
            finalisesOn: block.number + governance.TIME_TO_FINALISE(),
            timestamp: now,
            signature: [uint256(0), uint256(0)]
        });

        batches.push(newBatch);
        logger.logNewBatch(
            newBatch.committer,
            ZERO_BYTES32,
            _updatedRoot,
            batches.length - 1
        );
    }

    /**
     * @notice Returns the batch
     */
    function getBatch(uint256 _batch_id)
        public
        view
        returns (Types.Batch memory batch)
    {
        require(
            batches.length - 1 >= _batch_id,
            "Batch id greater than total number of batches, invalid batch id"
        );
        batch = batches[_batch_id];
    }

    /**
     * @notice SlashAndRollback slashes all the coordinator's who have built on top of the invalid batch
     * and rewards challengers. Also deletes all the batches after invalid batch
     */
    function SlashAndRollback() public isRollingBack {
        uint256 challengerRewards = 0;
        uint256 burnedAmount = 0;
        uint256 totalSlashings = 0;

        for (uint256 i = batches.length - 1; i >= invalidBatchMarker; i--) {
            // if gas left is low we would like to do all the transfers
            // and persist intermediate states so someone else can send another tx
            // and rollback remaining batches
            if (gasleft() <= governance.MIN_GAS_LIMIT_LEFT()) {
                // exit loop gracefully
                break;
            }

            // load batch
            Types.Batch memory batch = batches[i];

            // calculate challeger's reward
            uint256 _challengerReward = (batch.stakeCommitted.mul(2)).div(3);
            challengerRewards += _challengerReward;
            burnedAmount += batch.stakeCommitted.sub(_challengerReward);

            batches[i].stakeCommitted = 0;

            // delete batch
            delete batches[i];

            // queue deposits again
            depositManager.enqueue(batch.depositTree);

            totalSlashings++;

            logger.logBatchRollback(
                i,
                batch.committer,
                batch.stateRoot,
                batch.txCommit,
                batch.stakeCommitted
            );
            if (i == invalidBatchMarker) {
                // we have completed rollback
                // update the marker
                invalidBatchMarker = 0;
                break;
            }
        }

        // transfer reward to challenger
        (msg.sender).transfer(challengerRewards);

        // burn the remaning amount
        (BURN_ADDRESS).transfer(burnedAmount);

        // resize batches length
        batches.length = batches.length.sub(totalSlashings);

        logger.logRollbackFinalisation(totalSlashings);
    }
}

contract Rollup is RollupHelpers {
    /*********************
     * Constructor *
     ********************/
    constructor(address _registryAddr, bytes32 genesisStateRoot) public {
        nameRegistry = Registry(_registryAddr);

        logger = Logger(nameRegistry.getContractDetails(ParamManager.LOGGER()));
        depositManager = DepositManager(
            nameRegistry.getContractDetails(ParamManager.DEPOSIT_MANAGER())
        );

        governance = Governance(
            nameRegistry.getContractDetails(ParamManager.Governance())
        );
        merkleUtils = MTUtils(
            nameRegistry.getContractDetails(ParamManager.MERKLE_UTILS())
        );
        accountRegistry = BLSAccountRegistry(
            nameRegistry.getContractDetails(ParamManager.ACCOUNT_REGISTRY())
        );

        tokenRegistry = ITokenRegistry(
            nameRegistry.getContractDetails(ParamManager.TOKEN_REGISTRY())
        );

        fraudProof = IFraudProof(
            nameRegistry.getContractDetails(ParamManager.FRAUD_PROOF())
        );
        addNewBatch(
            ZERO_BYTES32,
            ZERO_BYTES32,
            genesisStateRoot,
            [uint256(0), uint256(0)]
        );
    }

    /**
     * @notice Submits a new batch to batches
     * @param _txs Compressed transactions .
     * @param _updatedRoot New balance tree root after processing all the transactions
     */
    function submitBatch(
        bytes calldata _txs,
        bytes32 _txRoot,
        bytes32 _updatedRoot,
        uint256[2] calldata signature
    ) external payable onlyCoordinator isNotRollingBack {
        require(
            msg.value >= governance.STAKE_AMOUNT(),
            "Not enough stake committed"
        );

        uint256 batchSize = _txs.length / TX_LEN;
        require(
            TX_LEN * batchSize == _txs.length,
            "excess data is not expected"
        );
        require(
            batchSize <= governance.MAX_TXS_PER_BATCH(),
            "Batch contains more transations than the limit"
        );
        bytes32 txCommit = keccak256(abi.encodePacked(_txs));
        require(
            BLS.isValidSignature(signature),
            "rollup: signature data is invalid"
        );
        addNewBatch(txCommit, _txRoot, _updatedRoot, signature);
    }

    /**
     * @notice finalise deposits and submit batch
     */
    function finaliseDepositsAndSubmitBatch(
        uint256 _subTreeDepth,
        Types.AccountMerkleProof calldata _zero_account_mp
    ) external payable onlyCoordinator isNotRollingBack {
        bytes32 depositSubTreeRoot = depositManager.finaliseDeposits(
            _subTreeDepth,
            _zero_account_mp,
            getLatestBalanceTreeRoot()
        );
        // require(
        //     msg.value >= governance.STAKE_AMOUNT(),
        //     "Not enough stake committed"
        // );

        bytes32 updatedRoot = merkleUtils.updateLeafWithSiblings(
            depositSubTreeRoot,
            _zero_account_mp.accountIP.pathToAccount,
            _zero_account_mp.siblings
        );

        // add new batch
        addNewBatchWithDeposit(updatedRoot, depositSubTreeRoot);
    }

    function disputeTxRoot(uint256 _batch_id, bytes calldata _txs) external {
        Types.Batch memory batch = batches[_batch_id];

        require(
            batch.stakeCommitted != 0,
            "Batch doesnt exist or is slashed already"
        );

        // check if batch is disputable
        require(block.number < batch.finalisesOn, "Batch already finalised");

        require(
            (_batch_id < invalidBatchMarker || invalidBatchMarker == 0),
            "Already successfully disputed. Roll back in process"
        );

        require(
            batch.txCommit != ZERO_BYTES32,
            "Cannot dispute blocks with no transaction"
        );
        if (batch.txRoot != merkleUtils.genRoot(_txs, TX_LEN)) {
            invalidBatchMarker = _batch_id;
            SlashAndRollback();
            return;
        }
    }

    function disputeSignature(
        uint256 _batch_id,
        bytes calldata _txs,
        uint256[4][] calldata pubkeys,
        bytes32[ACCOUNT_WITNESS_LENGTH][] calldata witnesses
    ) external {
        Types.Batch memory batch = batches[_batch_id];

        require(
            batch.stakeCommitted != 0,
            "Batch doesnt exist or is slashed already"
        );

        // check if batch is disputable
        require(block.number < batch.finalisesOn, "Batch already finalised");

        require(
            (_batch_id < invalidBatchMarker || invalidBatchMarker == 0),
            "Already successfully disputed. Roll back in process"
        );

        require(
            batch.txCommit != ZERO_BYTES32,
            "Cannot dispute blocks with no transaction"
        );

        uint256 batchSize = _txs.length / TX_LEN;
        require(batchSize > 0, "invalid batch size");
        require(
            TX_LEN * batchSize == _txs.length,
            "excess data is not expected"
        );

        uint256[2][] memory messages = new uint256[2][](batchSize);
        bytes memory txs = _txs;
        uint256 txOff = 32;
        for (uint256 i = 0; i < batchSize; i++) {
            // 1. extract accountID of sender
            uint256 accountID;
            // solium-disable-next-line security/no-inline-assembly
            assembly {
                let p_account_id := add(txs, add(txOff, accountIDPosition))
                accountID := mload(p_account_id)
                accountID := and(accountID, accountIDMask)
            }
            // 2. check if pub key with senderindex exists
            require(
                accountRegistry.exists(accountID, pubkeys[i], witnesses[i]),
                "account does not exists"
            );
            // 3. hash tx message
            bytes32 rawMessage;
            // solium-disable-next-line security/no-inline-assembly
            assembly {
                let p_tx_data := add(txs, txOff)
                rawMessage := keccak256(p_tx_data, TX_LEN)
            }
            // 4. map to point
            messages[i] = BLS.mapToPoint(rawMessage);
            txOff += TX_LEN;
        }
        if (!BLS.verifyMultiple(batch.signature, pubkeys, messages)) {
            invalidBatchMarker = _batch_id;
            SlashAndRollback();
            return;
        }
    }

    /**
     *  disputeBatch processes a transactions and returns the updated balance tree
     *  and the updated leaves.
     * @notice Gives the number of batches submitted on-chain
     * @return Total number of batches submitted onchain
     */
    function disputeBatch(
        uint256 _batch_id,
        Types.Transaction[] memory _txs,
        Types.BatchValidationProofs memory batchProofs
    ) public {
        {
            // load batch
            require(
                batches[_batch_id].stakeCommitted != 0,
                "Batch doesnt exist or is slashed already"
            );

            // check if batch is disputable
            require(
                block.number < batches[_batch_id].finalisesOn,
                "Batch already finalised"
            );

            require(
                (_batch_id < invalidBatchMarker || invalidBatchMarker == 0),
                "Already successfully disputed. Roll back in process"
            );

            require(
                batches[_batch_id].txCommit != ZERO_BYTES32,
                "Cannot dispute blocks with no transaction"
            );
        }

        bytes32 updatedBalanceRoot;
        bool isDisputeValid;
        (updatedBalanceRoot, isDisputeValid) = fraudProof.processBatch(
            batches[_batch_id - 1].stateRoot,
            batches[_batch_id - 1].accountRoot,
            _txs,
            batchProofs,
            batches[_batch_id].txCommit
        );

        // dispute is valid, we need to slash and rollback :(
        if (isDisputeValid) {
            // before rolling back mark the batch invalid
            // so we can pause and unpause
            invalidBatchMarker = _batch_id;
            SlashAndRollback();
            return;
        }

        // if new root doesnt match what was submitted by coordinator
        // slash and rollback
        if (updatedBalanceRoot != batches[_batch_id].stateRoot) {
            invalidBatchMarker = _batch_id;
            SlashAndRollback();
            return;
        }
    }


    /**
     * @notice Withdraw delay allows coordinators to withdraw their stake after the batch has been finalised
     * @param batch_id Batch ID that the coordinator submitted
     */
    function WithdrawStake(uint256 batch_id) public {
        Types.Batch memory committedBatch = batches[batch_id];
        require(
            committedBatch.stakeCommitted != 0,
            "Stake has been already withdrawn!!"
        );
        require(
            msg.sender == committedBatch.committer,
            "You are not the correct committer for this batch"
        );
        require(
            block.number > committedBatch.finalisesOn,
            "This batch is not yet finalised, check back soon!"
        );

        msg.sender.transfer(committedBatch.stakeCommitted);
        logger.logStakeWithdraw(
            msg.sender,
            committedBatch.stakeCommitted,
            batch_id
        );
        committedBatch.stakeCommitted = 0;
    }
}
