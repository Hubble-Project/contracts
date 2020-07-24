import * as walletHelper from "../../scripts/helpers/wallet";
import * as migrateUtils from "../../scripts/helpers/migration";
import * as utils from "../../scripts/helpers/utils";

var argv = require('minimist')(process.argv.slice(2));

const MTLib = artifacts.require("MerkleTreeUtils");
const IMT = artifacts.require("IncrementalTree.sol");
const nameRegistry = artifacts.require("NameRegistry");
const ParamManager = artifacts.require("ParamManager");
const ECVerify = artifacts.require("ECVerify");
const RollupUtils = artifacts.require("RollupUtils");
const Types = artifacts.require("Types");

// Test all stateless operations
contract("MerkleTreeUtils", async function (accounts) {
  var wallets: any;
  var firstDataBlock = utils.StringToBytes32("0x123");
  var secondDataBlock = utils.StringToBytes32("0x334");
  var thirdDataBlock = utils.StringToBytes32("0x4343");
  var fourthDataBlock = utils.StringToBytes32("0x334");
  var dataBlocks = [
    firstDataBlock,
    secondDataBlock,
    thirdDataBlock,
    fourthDataBlock,
  ];
  var dataLeaves = [
    utils.Hash(firstDataBlock),
    utils.Hash(secondDataBlock),
    utils.Hash(thirdDataBlock),
    utils.Hash(fourthDataBlock),
  ];

  var coordinator = "0x9fB29AAc15b9A4B7F17c3385939b007540f4d791";
  var max_depth = 4;
  var maxDepositSubtreeDepth = 1;

  let paramManagerInstance: any;
  let nameRegistryInstance: any;
  let MTUtilsInstance: any;
  before(async function () {
    wallets = walletHelper.generateFirstWallets(walletHelper.mnemonics, 10);
    if (argv.dn) {
      const typesLib: any = await migrateUtils.deployAndUpdate("Types", {})
      const ECVerifyLibInstance: any = await migrateUtils.deployAndUpdate("ECVerify", {})
      const rollupUtilsLibInstance: any = await migrateUtils.deployAndUpdate("RollupUtils", {})
      paramManagerInstance = await migrateUtils.deployAndUpdate("ParamManager", {})
      nameRegistryInstance = await migrateUtils.deployAndUpdate("NameRegistry", {})
  
      let governanceInstance: any = await migrateUtils.deployAndUpdate("Governance", {}, [max_depth, maxDepositSubtreeDepth]);
  
      await nameRegistryInstance.registerName(
        await paramManagerInstance.Governance(),
        governanceInstance.address
      )
  
      let libLinksMTU = {
        "ECVerify" : ECVerifyLibInstance.address,
        "ParamManager": paramManagerInstance.address,
        "RollupUtils": rollupUtilsLibInstance.address,
        "Types": typesLib.address,
      }
      MTUtilsInstance = await migrateUtils.deployAndUpdate("MerkleTreeUtils", libLinksMTU, [nameRegistryInstance.address])
  
      await nameRegistryInstance.registerName(
        await paramManagerInstance.MERKLE_UTILS(),
        MTUtilsInstance.address
      )
  
      console.log("MTUtilsInstance.address:", MTUtilsInstance.address)
    } else {
      MTUtilsInstance = await MTLib.deployed();
    }
  });

  it("ensure root created on-chain and via utils is the same", async function () {
    var coordinator =
      "0x012893657d8eb2efad4de0a91bcd0e39ad9837745dec3ea923737ea803fc8e3d";
    var maxSize = 4;
    var tempDataLeaves = [];
    tempDataLeaves[0] = coordinator;
    var numberOfDataLeaves = 2 ** maxSize;
    // create empty leaves
    for (var i = 1; i < numberOfDataLeaves; i++) {
      tempDataLeaves[i] =
        "0x290decd9548b62a8d60345a988386fc84ba6bc95484008f6362f93160ef3e563";
    }
    var mtlibInstance = await utils.getMerkleTreeUtils(nameRegistryInstance, paramManagerInstance);;
    var rootFromContract = await mtlibInstance.getMerkleRootFromLeaves(
      tempDataLeaves
    );
    // root that we are creating for on-chain data
    var rootWhileDeployingContracts =
      "0xfe55b4be5e50828667fb2dc97c9757fd0c295b19c6de05f4d8800ed128f66ad4";
    var generatedRoot = await utils.getMerkleRoot(tempDataLeaves, maxSize);
    var rootFromContract = await mtlibInstance.getMerkleRootFromLeaves(
      tempDataLeaves
    );
    assert.equal(
      rootFromContract,
      generatedRoot,
      "root generated off chain and on-chains should match"
    );
  });

  it("utils hash should be the same as keccak hash", async function () {
    var data = utils.StringToBytes32("0x123");

    var mtlibInstance = await utils.getMerkleTreeUtils(nameRegistryInstance, paramManagerInstance);;
    var hash = utils.Hash(data);

    var keccakHash = await mtlibInstance.keecakHash(data);
    expect(keccakHash).to.be.deep.eq(hash);
  });

  it("test get parent", async function () {
    var mtlibInstance = await utils.getMerkleTreeUtils(nameRegistryInstance, paramManagerInstance);;

    let localHash = utils.getParentLeaf(firstDataBlock, secondDataBlock);
    let contractHash = await mtlibInstance.getParent(
      firstDataBlock,
      secondDataBlock
    );

    expect(localHash).to.be.deep.eq(contractHash);
  });

  it("test index to path", async function () {
    var mtlibInstance = await utils.getMerkleTreeUtils(nameRegistryInstance, paramManagerInstance);;

    var result = await mtlibInstance.pathToIndex("10", 2);
    expect(result.toNumber()).to.be.deep.eq(2);

    var result2 = await mtlibInstance.pathToIndex("11", 2);
    expect(result2.toNumber()).to.be.deep.eq(3);

    var result3 = await mtlibInstance.pathToIndex("111", 3);
    expect(result3.toNumber()).to.be.deep.eq(7);

    // var result4 = await mtlibInstance.pathToIndex(
    //   "11111111111111111111111",
    //   "11111111111111111111111".length
    // );
    // expect(result4.toNumber()).to.be.deep.eq(8388607);
  });

  it("[LEAF] [STATELESS] verifying correct proof", async function () {
    var mtlibInstance = await utils.getMerkleTreeUtils(nameRegistryInstance, paramManagerInstance);;

    var root = await mtlibInstance.getMerkleRoot(dataBlocks);

    var siblings: Array<string> = [
      dataLeaves[1],
      utils.getParentLeaf(dataLeaves[2], dataLeaves[3]),
    ];

    var leaf = dataLeaves[0];

    var path: string = "00";

    var isValid = await mtlibInstance.verifyLeaf(root, leaf, path, siblings);

    expect(isValid).to.be.deep.eq(true);
  });

  it("[DATABLOCK] [STATELESS] verifying correct proof", async function () {
    var mtlibInstance = await utils.getMerkleTreeUtils(nameRegistryInstance, paramManagerInstance);;

    var root = await mtlibInstance.getMerkleRoot(dataBlocks);

    var siblings: Array<string> = [
      dataLeaves[1],
      utils.getParentLeaf(dataLeaves[2], dataLeaves[3]),
    ];

    var leaf = dataBlocks[0];

    var path: string = "00";

    var isValid = await mtlibInstance.verify(root, leaf, path, siblings);

    expect(isValid).to.be.deep.eq(true);
  });

  it("[LEAF] [STATELESS] verifying proof with wrong path", async function () {
    var mtlibInstance = await utils.getMerkleTreeUtils(nameRegistryInstance, paramManagerInstance);;
    // create merkle tree and get root
    var root = await mtlibInstance.getMerkleRoot(dataBlocks);
    var siblings: Array<string> = [
      dataLeaves[1],
      utils.getParentLeaf(dataLeaves[2], dataLeaves[3]),
    ];
    var leaf = dataLeaves[0];
    var path: string = "01";
    var isValid = await mtlibInstance.verifyLeaf(root, leaf, path, siblings);
    expect(isValid).to.be.deep.eq(false);
  });

  it("[DATABLOCK] [STATELESS] verifying proof with wrong path", async function () {
    var mtlibInstance = await utils.getMerkleTreeUtils(nameRegistryInstance, paramManagerInstance);;

    // create merkle tree and get root
    var root = await mtlibInstance.getMerkleRoot(dataBlocks);

    var siblings: Array<string> = [
      dataLeaves[1],
      utils.getParentLeaf(dataLeaves[2], dataLeaves[3]),
    ];
    var leaf = dataLeaves[0];
    var path: string = "01";
    var isValid = await mtlibInstance.verifyLeaf(root, leaf, path, siblings);
    expect(isValid).to.be.deep.eq(false);
  });

  it("[LEAF] [STATELESS] verifying other leaves", async function () {
    var mtlibInstance = await utils.getMerkleTreeUtils(nameRegistryInstance, paramManagerInstance);;

    var root = await mtlibInstance.getMerkleRoot(dataBlocks);

    var siblings: Array<string> = [
      dataLeaves[0],
      utils.getParentLeaf(dataLeaves[2], dataLeaves[3]),
    ];
    var leaf = dataLeaves[1];
    var path: string = "01";
    var isValid = await mtlibInstance.verifyLeaf(root, leaf, path, siblings);
    expect(isValid).to.be.deep.eq(true);
  });

  it("[DATABLOCK] [STATELESS] verifying other leaves", async function () {
    var mtlibInstance = await utils.getMerkleTreeUtils(nameRegistryInstance, paramManagerInstance);;

    var root = await mtlibInstance.getMerkleRoot(dataBlocks);

    var siblings: Array<string> = [
      dataLeaves[0],
      utils.getParentLeaf(dataLeaves[2], dataLeaves[3]),
    ];
    var leaf = dataLeaves[1];
    var path: string = "01";
    var isValid = await mtlibInstance.verifyLeaf(root, leaf, path, siblings);
    expect(isValid).to.be.deep.eq(true);
  });

  it("[DATABLOCK] [STATELESS] path greater than depth", async function () {
    var mtlibInstance = await utils.getMerkleTreeUtils(nameRegistryInstance, paramManagerInstance);;

    var root = await mtlibInstance.getMerkleRoot(dataBlocks);

    var siblings: Array<string> = [
      dataLeaves[0],
      utils.getParentLeaf(dataLeaves[2], dataLeaves[3]),
    ];
    var leaf = dataLeaves[1];
    var path: string = "010";
    var isValid = await mtlibInstance.verifyLeaf(root, leaf, path, siblings);

    // TODO fix
    expect(isValid).to.be.deep.eq(false);
  });
});
