require("dotenv").config();
require("@nomicfoundation/hardhat-ethers");
require("@nomicfoundation/hardhat-verify");

const rpcUrl = process.env.RPC_URL || "";
const accounts = process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [];

module.exports = {
  defaultNetwork: "sepolia",
  solidity: {
    compilers: [
      {
        version: "0.8.31",
        settings: {
          optimizer: {
            enabled: true,
            runs: 1
          },
          viaIR: true,
          evmVersion: "cancun",
          metadata: {
            bytecodeHash: "none"
          }
        }
      }
    ]
  },
  networks: {
    sepolia: {
      url: rpcUrl,
      accounts
    }
  },
  etherscan: {
    apiKey: process.env.ETHERSCAN_API_KEY || ""
  },
  paths: {
    sources: "contracts",
    tests: "test",
    cache: "hh-cache",
    artifacts: "hh-artifacts"
  }
};
