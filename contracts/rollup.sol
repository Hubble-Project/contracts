pragma solidity ^0.5.15;
pragma experimental ABIEncoderV2;

import {SafeMath} from "@openzeppelin/contracts/math/SafeMath.sol";
// import "solidity-bytes-utils/contracts/BytesLib.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {ITokenRegistry} from "./interfaces/ITokenRegistry.sol";
import {IFraudProof} from "./interfaces/IFraudProof.sol";
import {ParamManager} from "./libs/ParamManager.sol";
import {Types} from "./libs/Types.sol";
import {RollupUtils} from "./libs/RollupUtils.sol";
import {Logger} from "./logger.sol";
import {POB} from "./POB.sol";
import {MerkleTreeUtils as MTUtils} from "./MerkleTreeUtils.sol";
import {NameRegistry as Registry} from "./NameRegistry.sol";
import {Governance} from "./Governance.sol";
import {DepositManager} from "./DepositManager.sol";

import {Tx} from "./libs/Tx.sol";
import {BLS} from "./libs/BLS.sol";
import {BLSAccountRegistry} from "./BLSAccountRegistry.sol";

contract Rollup {
  bytes32 public constant ZERO_BYTES32 = 0x0000000000000000000000000000000000000000000000000000000000000000;
  address payable constant BURN_ADDRESS = 0x0000000000000000000000000000000000000000;

  using SafeMath for uint256;
  using Tx for bytes;

  // External contracts
  DepositManager public depositManager;
  BLSAccountRegistry public accountRegistry;
  Logger public logger;
  ITokenRegistry public tokenRegistry;
  Registry public nameRegistry;
  MTUtils public merkleUtils;
  IFraudProof public fraudProof;
  Governance public governance;

  // Types.Batch[] public batches;
  mapping(uint256 => Types.Batch) batches;
  uint256 batchPointer = 0;

  // this variable will be greater than 0 if
  // there is rollback in progress
  // will be reset to 0 once rollback is completed
  uint256 public invalidBatchMarker;

  modifier onlyCoordinator() {
    POB pobContract = POB(nameRegistry.getContractDetails(ParamManager.POB()));
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

  /*********************
   * Constructor *
   ********************/
  constructor(address _registryAddr, bytes32 genesisStateRoot) public {
    nameRegistry = Registry(_registryAddr);

    logger = Logger(nameRegistry.getContractDetails(ParamManager.LOGGER()));
    depositManager = DepositManager(nameRegistry.getContractDetails(ParamManager.DEPOSIT_MANAGER()));

    governance = Governance(nameRegistry.getContractDetails(ParamManager.Governance()));
    merkleUtils = MTUtils(nameRegistry.getContractDetails(ParamManager.MERKLE_UTILS()));
    accountRegistry = BLSAccountRegistry(nameRegistry.getContractDetails(ParamManager.ACCOUNT_REGISTRY()));

    tokenRegistry = ITokenRegistry(nameRegistry.getContractDetails(ParamManager.TOKEN_REGISTRY()));

    fraudProof = IFraudProof(nameRegistry.getContractDetails(ParamManager.FRAUD_PROOF()));
    addNewBatch(ZERO_BYTES32, ZERO_BYTES32, genesisStateRoot, [uint256(0), uint256(0)]);
  }

  /**
   * @notice Returns the latest state root
   */
  function getLatestBalanceTreeRoot() public view returns (bytes32) {
    return batches[batchPointer - 1].stateRoot;
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
      timestamp: block.timestamp,
      signature: signature
    });

    batches[batchPointer] = newBatch;
    logger.logNewBatch(newBatch.committer, txCommit, _updatedRoot, batchPointer);
    batchPointer += 1;
  }

  function addNewBatchWithDeposit(bytes32 _updatedRoot, bytes32 depositRoot) internal {
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
      timestamp: block.timestamp,
      signature: [uint256(0), uint256(0)]
    });

    batches[batchPointer] = newBatch;
    logger.logNewBatch(newBatch.committer, ZERO_BYTES32, _updatedRoot, batchPointer);
    batchPointer += 1;
  }

  /**
   * @notice SlashAndRollback slashes all the coordinator's who have built on top of the invalid batch
   * and rewards challengers. Also deletes all the batches after invalid batch
   */
  function SlashAndRollback() public isRollingBack {
    uint256 challengerRewards = 0;
    uint256 burnedAmount = 0;
    uint256 totalSlashings = 0;

    for (uint256 i = batchPointer - 1; i >= invalidBatchMarker; i--) {
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

      logger.logBatchRollback(i, batch.committer, batch.stateRoot, batch.txCommit, batch.stakeCommitted);
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
    // batches.length = batches.length.sub(totalSlashings);
    batchPointer -= totalSlashings;

    logger.logRollbackFinalisation(totalSlashings);
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
    require(msg.value >= governance.STAKE_AMOUNT(), "Not enough stake committed");
    bytes memory txs = _txs;
    uint256 batchSize = txs.size();
    require(batchSize > 0, "Rollup: empty batch");
    require(!txs.hasExcessData(), "Rollup: excess data");
    require(batchSize <= governance.MAX_TXS_PER_BATCH(), "Batch contains more transations than the limit");
    bytes32 txCommit = keccak256(abi.encodePacked(_txs));
    require(BLS.isValidSignature(signature), "Rollup: signature data is invalid");
    addNewBatch(txCommit, _txRoot, _updatedRoot, signature);
  }

  /**
   * @notice finalise deposits and submit batch
   */
  function finaliseDepositsAndSubmitBatch(uint256 _subTreeDepth, Types.AccountMerkleProof calldata _zero_account_mp)
    external
    payable
    onlyCoordinator
    isNotRollingBack
  {
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

    require(batch.stakeCommitted != 0, "Batch doesnt exist or is slashed already");

    // check if batch is disputable
    require(block.number < batch.finalisesOn, "Batch already finalised");

    require(
      (_batch_id < invalidBatchMarker || invalidBatchMarker == 0),
      "Already successfully disputed. Roll back in process"
    );

    require(batch.txCommit != ZERO_BYTES32, "Cannot dispute blocks with no transaction");
    if (batch.txRoot != merkleUtils.calculateRootTruncated(_txs.toLeafs())) {
      invalidBatchMarker = _batch_id;
      SlashAndRollback();
      return;
    }
  }

  struct InvalidSignatureProof {
    uint256[4][] pubkeys;
    bytes32[ACCOUNT_WITNESS_LENGTH][] witnesses;
  }

  uint256 constant ACCOUNT_WITNESS_LENGTH = 31;

  function disputeSignature(
    uint256 _batch_id,
    InvalidSignatureProof calldata proof,
    bytes calldata _txs
  ) external {
    Types.Batch memory batch = batches[_batch_id];

    require(batch.stakeCommitted != 0, "Batch doesnt exist or is slashed already");

    // check if batch is disputable
    require(block.number < batch.finalisesOn, "Batch already finalised");

    require(
      (_batch_id < invalidBatchMarker || invalidBatchMarker == 0),
      "Already successfully disputed. Roll back in process"
    );

    require(batch.txCommit != ZERO_BYTES32, "Cannot dispute blocks with no transaction");

    bytes memory txs = _txs;
    uint256 batchSize = txs.size();
    require(batchSize > 0, "Rollup: empty batch");
    require(!txs.hasExcessData(), "Rollup: excess data");
    uint256[2][] memory messages = new uint256[2][](batchSize);
    for (uint256 i = 0; i < batchSize; i++) {
      uint256 accountID = txs.senderOf(i);
      // What if account not exists?
      // Then this batch must be subjected to invalid state transition
      require(
        accountRegistry.exists(accountID, proof.pubkeys[i], proof.witnesses[i]),
        "Rollup: account does not exists"
      );
      messages[i] = txs.mapToPoint(i);
    }
    if (!BLS.verifyMultiple(batch.signature, proof.pubkeys, messages)) {
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
    bytes memory _txs,
    Types.InvalidTransitionProof memory proof
  ) public {
    // load batch
    require(batches[_batch_id].stakeCommitted != 0, "Batch doesnt exist or is slashed already");

    // check if batch is disputable
    require(block.number < batches[_batch_id].finalisesOn, "Batch already finalised");

    require(
      (_batch_id < invalidBatchMarker || invalidBatchMarker == 0),
      "Already successfully disputed. Roll back in process"
    );

    require(batches[_batch_id].txCommit != ZERO_BYTES32, "Cannot dispute blocks with no transaction");

    bytes32 updatedBalanceRoot;
    bool isDisputeValid;
    (updatedBalanceRoot, isDisputeValid) = fraudProof.processBatch(batches[_batch_id - 1].stateRoot, _txs, proof);

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
    require(committedBatch.stakeCommitted != 0, "Stake has been already withdrawn!!");
    require(msg.sender == committedBatch.committer, "You are not the correct committer for this batch");
    require(block.number > committedBatch.finalisesOn, "This batch is not yet finalised, check back soon!");
    msg.sender.transfer(committedBatch.stakeCommitted);
    logger.logStakeWithdraw(msg.sender, committedBatch.stakeCommitted, batch_id);
    committedBatch.stakeCommitted = 0;
  }
}
