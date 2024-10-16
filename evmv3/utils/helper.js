let fs = require("fs");
let path = require("path");

async function stringToHex(str) {
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

async function getFeeList(chain) {
  let p = path.join(__dirname, "../constants/fee.json");
  let tokenFees;
  if (!fs.existsSync(p)) {
    throw "not fee ..";
  }
  let rawdata = fs.readFileSync(p);
  tokenFees = JSON.parse(rawdata);
  if (!tokenFees[chain]) {
    throw "not fee ..";
  }

  return tokenFees[chain];
}

async function getFeeInfo(chain, token) {
  let p = path.join(__dirname, "../constants/fee.json");
  let tokenFees;
  if (!fs.existsSync(p)) {
    throw "not fee ..";
  }

  let rawdata = fs.readFileSync(p);
  tokenFees = JSON.parse(rawdata);
  if (!tokenFees[chain]) {
    throw "not target chain fee ..";
  }

  if (!tokenFees[chain][token]) {
    throw "not token fee ..";
  }

  return tokenFees[chain][token];
}

async function getChain(network) {
  let chains = await getChainList();

  for (let i = 0; i < chains.length; i++) {
    if (chains[i].chain === network || chains[i].chainId == network) {
      return chains[i];
    }
  }

  throw "can't find the chain";
}

async function getChainList() {
  let p = path.join(__dirname, "../constants/chains.json");
  let chains;
  if (!fs.existsSync(p)) {
    throw "not chains ..";
  } else {
    let rawdata = fs.readFileSync(p);
    chains = JSON.parse(rawdata);
  }

  return chains;
}

async function getTokenList(chainId) {
  let p = path.join(__dirname, "../constants/tokens.json");
  let tokens;
  if (!fs.existsSync(p)) {
    throw "not tokens ..";
  } else {
    let rawdata = fs.readFileSync(p);
    tokens = JSON.parse(rawdata);
    if (!tokens[chainId]) {
      throw "no tokens ..";
    }
  }
  let tokenList = Object.keys(tokens[chainId]);

  return tokenList;
}

async function getToken(network, token) {
  let chain = await getChain(network);
  let chainId = chain.chainId;

  if (chainId === 1360100178526209 || chainId === 1360100178526210) {
    // near
    if (token.length > 4) {
      return token;
    }
  } else if (chainId === 728126428 || chainId === 728126429) {
    // tron
    if (token.length === 34) {
      return token;
    }
  } else {
    if (token.substr(0, 2) === "0x") {
      return token;
    }
  }
  let tokens = await getTokensFromFile(chain.chain);
  if (tokens[chain.chain][token]) {
    return tokens[chain.chain][token];
  }

  throw "token not support ..";
}

async function getTokensFromFile(network) {
  let p = path.join(__dirname, "../constants/tokens.json");
  let tokens;
  if (!fs.existsSync(p)) {
    tokens = {};
    tokens[network] = {};
  } else {
    let rawdata = fs.readFileSync(p);
    tokens = JSON.parse(rawdata);
    if (!tokens[network]) {
      tokens[network] = {};
    }
  }

  return tokens;
}

async function getFeeConfig(subject) {
  let configFile = "../constants/" + subject + ".json";
  let p = path.join(__dirname, configFile);
  console.log("fee path", p);
  let configs = {};
  if (fs.existsSync(p)) {
    let rawdata = fs.readFileSync(p);
    configs = JSON.parse(rawdata);
  }
  return configs;
}

module.exports = {
  getChain,
  getToken,
  getRole,
  getTokenList,
  getFeeInfo,
  getChainList,
  stringToHex,
  getFeeList,
  getFeeConfig,
};
