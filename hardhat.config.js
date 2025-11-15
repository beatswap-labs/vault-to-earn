require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();

const { BNB_RPC_URL, DEPLOYER_PRIVATE_KEY } = process.env;

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.20",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200
      }
    }
  },
  paths: {
    sources: "./bnb/contracts",
    tests: "./bnb/test",
    cache: "./bnb/cache",
    artifacts: "./bnb/artifacts"
  },
  networks: {
    hardhat: {},
    opbnb: {
      url: BNB_RPC_URL || "",
      chainId: 56,
      accounts: DEPLOYER_PRIVATE_KEY ? [DEPLOYER_PRIVATE_KEY] : []
    }
  }
};
