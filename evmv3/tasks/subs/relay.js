let { create, readFromFile, writeToFile } = require("../../utils/create.js");
let { getChain, getToken, getChainList, getFeeList, stringToHex} = require("../../utils/helper");

async function getRelay(network) {
  let BridgeAndRelay = await ethers.getContractFactory("BridgeAndRelay");
  let deployment = await readFromFile(network);
  let addr = deployment[network]["bridgeProxy"];
  if (!addr) {
    throw "relay not deployed.";
  }

  let relay = BridgeAndRelay.attach(addr);

  console.log("relay address:", relay.address);
  return relay;
}

task("relay:deploy", "mos relay deploy")
  .addOptionalParam("wrapped", "native wrapped token address", "", types.string)
  .addOptionalParam("client", "light client address", "", types.string)
  .addOptionalParam("auth", "auth address", "0xACC31A6756B60304C03d6626fc98c062E4539CCA", types.string)
    .addOptionalParam("fee", "fee service address", "", types.string)
  .setAction(async (taskArgs, hre) => {
    const accounts = await ethers.getSigners();
    const deployer = accounts[0];
    console.log("deployer address:", deployer.address);

    let chain = await getChain(hre.network.config.chainId);

    let client = taskArgs.client === "" ? chain.lightNode : taskArgs.client;
    let wrapped = taskArgs.wrapped === "" ? chain.wToken : taskArgs.wrapped;

      let authority = taskArgs.auth === "" ? chain.auth : taskArgs.auth;
      let feeService = taskArgs.fee === "" ? chain.feeService : taskArgs.fee;

    let implAddr = await create(hre, deployer, "BridgeAndRelay", [], [], "");

    let BridgeAndRelay = await ethers.getContractFactory("BridgeAndRelay");
    let data = await BridgeAndRelay.interface.encodeFunctionData("initialize", [wrapped, authority]);
    let proxy_salt = process.env.BRIDGE_PROXY_SALT;

    let bridge = await create(hre, deployer, "OmniServiceProxy", ["address", "bytes"], [implAddr, data], proxy_salt);

    let relay = BridgeAndRelay.attach(bridge);

    console.log("set light client manager: ", client);
    await (await relay.setServiceContract(1, client)).wait();

      console.log("set fee service: ", feeService);
      await (await relay.setServiceContract(2, feeService)).wait();

    console.log("wToken", await relay.getServiceContract(0));
      console.log("client", await relay.getServiceContract(1));
      console.log("fee", await relay.getServiceContract(2));

    let deployment = await readFromFile(hre.network.name);
    deployment[hre.network.name]["bridgeProxy"] = bridge;
    await writeToFile(deployment);

    // todo contract verify
  });

task("relay:upgrade", "upgrade bridge evm contract in proxy")
  .addOptionalParam("impl", "implementation address", "", types.string)
  .addOptionalParam("auth", "Send through authority call, default false", false, types.boolean)
  .setAction(async (taskArgs, hre) => {
    const { deploy } = hre.deployments;
    const accounts = await ethers.getSigners();
    const deployer = accounts[0];
    console.log("deployer address:", deployer.address);

    let implAddr = taskArgs.impl;
    if (implAddr === "") {
      implAddr = await create(hre, deployer, "BridgeAndRelay", [], [], "");
    }

    let relay = await getRelay(hre.network.name);

    console.log("pre impl", await relay.getImplementation());
    await (await relay.upgradeToAndCall(implAddr, "0x")).wait();
    console.log("new impl", await relay.getImplementation());
  });

task("relay:setServiceContract", "set contract")
  .addParam("type", "contract type, 0-wtoken, 1-lightnode, 2-feeservice, 3-router, 4-register, 5-limit")
  .addParam("contract", "contract address")
  .setAction(async (taskArgs, hre) => {
    const accounts = await ethers.getSigners();
    const deployer = accounts[0];

    console.log("deployer address is:", deployer.address);

    let bridge = await getRelay(hre.network.name);

    {
      await (await bridge.setServiceContract(taskArgs.type, taskArgs.contract)).wait();
      console.log("contract", await bridge.getServiceContract(taskArgs.type));
    }
  });

task("relay:setDistributeRate", "set distribute rate")
  .addParam("type", "distribute id, 0 - vault, 1 - relayer, 2 - protocol")
  .addOptionalParam("receiver", "receiver address", "0x0000000000000000000000000000000000000DEF", types.string)
  .addParam("rate", "The percentage value of the fee charged, unit 0.000001")
  .setAction(async (taskArgs, hre) => {
    const accounts = await ethers.getSigners();
    const deployer = accounts[0];
    console.log("deployer address:", deployer.address);

    let relay = await getRelay(hre.network.name);

    await (await relay.setDistributeRate(taskArgs.type, taskArgs.receiver, taskArgs.rate)).wait();
  });

task("relay:registerChain", "register Chain")
  .addParam("chain", "chainId")
  .addOptionalParam("address", "chainId => address")
  .addOptionalParam("type", "chain type, default 1", 1, types.int)
  .setAction(async (taskArgs, hre) => {
    const accounts = await ethers.getSigners();
    const deployer = accounts[0];
    console.log("deployer address:", deployer.address);

    let relay = await getRelay(hre.network.name);

    let mos = taskArgs.address;
      if (mos.substr(0, 2) !== "0x") {
          mos = "0x" + stringToHex(taskArgs.address);

          console.log(`mos address: ${taskArgs.address} (${mos})`);
      }


    await (await relay.registerChain([taskArgs.chain], [mos], taskArgs.type)).wait();
    console.log(`register chain ${taskArgs.chain} address ${taskArgs.address} success`);
  });

/*
task("relay:grantRole", "grant Role")
  .addParam("role", "role address")
  .addParam("account", "account address")
  .addOptionalParam("grant", "grant or revoke", true, types.boolean)
  .setAction(async (taskArgs, hre) => {
    const accounts = await ethers.getSigners();
    const deployer = accounts[0];
    console.log("deployer address:", deployer.address);

    let relay = await getRelay(hre.network.name);

    let role;
    if (taskArgs.role === "upgrade" || taskArgs.role === "upgrader") {
      role = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("UPGRADER_ROLE"));
    } else if (taskArgs.role === "manage" || taskArgs.role === "manager") {
      role = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("MANAGER_ROLE"));
    } else {
      role = ethers.constants.HashZero;
    }

    if (taskArgs.grant) {
      await (await relay.grantRole(role, taskArgs.account)).wait();
      console.log(`grant ${taskArgs.account} role ${role}`);
    } else {
      await relay.revokeRole(role, taskArgs.account);
      console.log(`revoke ${taskArgs.account} role ${role}`);
    }
  });
*/
task("relay:updateToken", "update token bridge and fee to target chain")
  .addParam("token", "relay chain token name")
  .setAction(async (taskArgs, hre) => {
    const accounts = await ethers.getSigners();
    const deployer = accounts[0];
    // console.log("deployer address:", deployer.address);

    await hre.run("bridge:updateToken", {
      token: taskArgs.token,
    });

    let tokenAddr = await getToken(hre.network.config.chainId, taskArgs.token);
    let token = await ethers.getContractAt("IERC20MetadataUpgradeable", tokenAddr);
    let decimals = await token.decimals();
    // console.log(`token ${taskArgs.token} address: ${token.address}, decimals ${decimals}`);

    let feeList = await getFeeList(taskArgs.token);
    let chainList = Object.keys(feeList);
    for (let i = 0; i < chainList.length; i++) {
      let chain = await getChain(chainList[i]);
      let chainFee = feeList[chain.name];

      let targetToken = await getToken(chain.chainId, taskArgs.token);
      // console.log(`target ${chain.chainId}, ${targetToken}, ${chainFee.decimals}`)
      await hre.run("register:mapToken", {
        token: tokenAddr,
        chain: chain.chainId,
        target: targetToken,
        decimals: chainFee.decimals,
      });

      await hre.run("register:setTokenFee", {
        token: tokenAddr,
        chain: chain.chainId,
        lowest: chainFee.fee.min,
        highest: chainFee.fee.max,
        rate: chainFee.fee.rate,
        decimals: decimals,
      });

      let transferOutFee = chainFee.outFee;
      if (transferOutFee === undefined) {
        transferOutFee = { min: "0", max: "0", rate: "0" };
      }
      await hre.run("register:setTransferOutFee", {
        token: tokenAddr,
        chain: chain.chainId,
        lowest: transferOutFee.min,
        highest: transferOutFee.max,
        rate: transferOutFee.rate,
        decimals: decimals,
      });
    }

    console.log(`Update token ${taskArgs.token} success`);
  });

task("relay:list", "List relay infos")
  .addOptionalParam("mos", "The mos address, default mos", "mos", types.string)
  .setAction(async (taskArgs, hre) => {
    const accounts = await ethers.getSigners();
    const deployer = accounts[0];
    const chainId = await deployer.getChainId();
    console.log("deployer address:", deployer.address);

    let relay = await getRelay(hre.network.name);

    let tokenmanager = await relay.tokenRegister();
    let selfChainId = await relay.selfChainId();
    console.log("selfChainId:\t", selfChainId.toString());
    // console.log("mos:", await relay.mos());
    console.log("Impl:\t", await relay.getImplementation());
    console.log("wToken address:\t", await relay.getServiceContract(0));
    console.log("fee Service:\t", await relay.getServiceContract(2));
    console.log("light Client Manager:\t", await relay.getServiceContract(1));
    console.log("Token manager:\t", await relay.tokenRegister());

    // console.log("fee receiver:\t", await relay.nativeFeeReceiver());

    // console.log("base fee swap:\t", await relay.baseGasLookup(0, 0));
    // console.log("base fee deposit:\t", await relay.baseGasLookup(0, 1));
    // console.log("base fee intertransfer:\t", await relay.baseGasLookup(0, 2));

    let vaultFee = await relay.distributeRate(0);
    let relayFee = await relay.distributeRate(1);
    let protocolFee = await relay.distributeRate(2);
    console.log(`distribute vault rate: rate(${vaultFee[1]})`);
    console.log(`distribute relay rate: rate(${relayFee[1]}), receiver(${relayFee[0]})`);
    console.log(`distribute protocol rate: rate(${protocolFee[1]}), receiver(${protocolFee[0]})`);

    let chainList = await getChainList(chainId);
    console.log(chainId)
    console.log("\nRegister chains:");
    let chains = [selfChainId];
    for (let i = 0; i < chainList.length; i++) {
      //console.log(chainList[i].chainId)
      let contract = await relay.mosContracts(chainList[i].chainId);
      if (contract !== "0x") {
        let chaintype = await relay.chainTypes(chainList[i].chainId);
        console.log(`type(${chaintype}) ${chainList[i].chainId}\t => ${contract} `);
        chains.push(chainList[i].chainId);
      }
    }
  });

task("relay:tokenInfo", "List token infos")
  .addOptionalParam("token", "The token address, default wtoken", "wtoken", types.string)
  .setAction(async (taskArgs, hre) => {
    let relay = await getRelay(hre.network.name);
    let tokenManager = await relay.tokenRegister();
    let manager = await ethers.getContractAt("TokenRegisterV3", tokenManager);
    console.log("Token manager:\t", manager.address);

    let tokenAddr = taskArgs.token;
    if (tokenAddr === "wtoken") {
      tokenAddr = await relay.wToken();
    }
    tokenAddr = await getToken(hre.network.config.chainId, tokenAddr);

    await hre.run("bridge:tokenInfo", { token: taskArgs.token });

    let token = await manager.tokenList(tokenAddr);
    //console.log(`token decimals:\t ${token.decimals}`);
    console.log(`vault address: ${token.vaultToken}`);

    let vault = await ethers.getContractAt("VaultTokenV3", token.vaultToken);
    let totalVault = await vault.totalVault();
    console.log(`total token:\t ${totalVault}`);
    let totalSupply = await vault.totalSupply();
    console.log(`total vault supply: ${totalSupply}`);

    let chainList = await getChainList(hre.network.name);
    let chains = [hre.network.config.chainId];
    for (let i = 0; i < chainList.length; i++) {
      let contract = await relay.mosContracts(chainList[i].chainId);
      if (contract !== "0x") {
        chains.push(chainList[i].chainId);
      }
    }
    console.log(`chains:`);
    for (let i = 0; i < chains.length; i++) {
      let info = await manager.getTargetFeeInfo(tokenAddr, chains[i]);
      console.log(`${chains[i]}\t => ${info[0]} (${info[1]}), `);

      let balance = await vault.getVaultByChainId(chains[i]);
      console.log(`\t vault(${balance}), fee min(${info[2][0]}), max(${info[2][1]}), rate(${info[2][2]})`);
    }
  });
