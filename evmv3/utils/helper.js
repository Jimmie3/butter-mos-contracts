let fs = require("fs");
let path = require("path");

async function sleep(delay) {
  return new Promise((resolve) => setTimeout(resolve, delay));
}

function stringToHex(str) {
  return str
    .split("")
    .map(function (c) {
      return ("0" + c.charCodeAt(0).toString(16)).slice(-2);
    })
    .join("");
}

function getRole(role) {
  if (role.substr(0, 2) === "0x") {
    return role;
  }
  if (role === "admin") {
    return "0x0000000000000000000000000000000000000000000000000000000000000000";
  }
  let roleName = role;
  if (role === "manager") {
    roleName = "MANAGER_ROLE";
  } else if (role === "minter") {
    roleName = "MINTER_ROLE";
  }
  return ethers.utils.keccak256(ethers.utils.toUtf8Bytes(roleName));
}

function isRelayChain(network) {
  let networks = [22776, "22776", "Mapo", "Map", 212, "212", "Makalu"];
  return networks.includes(network);
}

function isTron(network) {
  let networks = [728126428, "728126428", "Tron", 3448148188, "3448148188", "TronTest"];
  return networks.includes(network);
}

function isSolana(network) {
  let networks = [1360108768460811, 1360108768460801, "1360108768460811", "1360108768460801", "Solana", "SolanaDev"];
  return networks.includes(network);
}

function isBtc(network) {
  let networks = [313230561203979757n, "313230561203979757", "Btc"];
  return networks.includes(network);
}

function isTestnet(chainId) {
  let testnets = [
    212,
    "Makalu",
    11155111,
    "Sepolia",
    97,
    "BscTest",
    300,
    "zkSyncTest",
    421614,
    "ArbitrumSepolia",
    53457,
    "DodoTest",
    11155420,
    "OpSepolia",
    80002,
    "Amoy",
    3448148188,
    "TronTest",
    1360104473493506,
    "TonTest",
    1360108768460802,
    "SolanaDev",
    1360095883558914,
    "BtcTest",
    "1360095883558916",
    "XrpTest"
  ];
  return testnets.includes(chainId);
}

module.exports = {
  getRole,
  stringToHex,
  isRelayChain,
  isTron,
  isTestnet,
  sleep,
  isSolana,
  isBtc
};
