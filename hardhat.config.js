import "dotenv/config";
import { defineConfig } from "hardhat/config";
import hardhatEthers from "@nomicfoundation/hardhat-ethers";
import hardhatVerify from "@nomicfoundation/hardhat-verify";

const rpcUrl = process.env.RPC_URL || "";
const accounts = process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [];

export default defineConfig({
  plugins: [hardhatEthers, hardhatVerify],
  solidity: {
    compilers: [
      {
        version: "0.8.33",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200
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
      type: "http",
      chainType: "l1",
      chainId: 11155111,
      url: rpcUrl,
      accounts
    }
  },
  verify: {
    etherscan: {
      apiKey: process.env.ETHERSCAN_API_KEY || ""
    }
  },
  paths: {
    sources: "contracts",
    tests: "test",
    cache: "hh-cache",
    artifacts: "hh-artifacts"
  }
});
