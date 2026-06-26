import "dotenv/config";
import { defineConfig } from "hardhat/config";
import hardhatEthers from "@nomicfoundation/hardhat-ethers";
import hardhatFoundry from "@nomicfoundation/hardhat-foundry";
import hardhatVerify from "@nomicfoundation/hardhat-verify";

const rpcUrl = process.env.RPC_URL;
const accounts = process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [];

const networks = rpcUrl
  ? {
      sepolia: {
        type: "http",
        chainType: "l1",
        chainId: 11155111,
        url: rpcUrl,
        accounts,
      },
    }
  : {};

export default defineConfig({
  plugins: [hardhatEthers, hardhatFoundry, hardhatVerify],
  solidity: {
    compilers: [
      {
        version: "0.8.33",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
          viaIR: true,
          evmVersion: "cancun",
          metadata: {
            bytecodeHash: "none",
          },
        },
      },
    ],
  },
  networks,
  verify: {
    etherscan: {
      apiKey: process.env.ETHERSCAN_API_KEY || "",
    },
  },
  paths: {
    sources: "contracts",
    // Hardhat is only used for contract verification here; Foundry owns .t.sol tests.
    tests: "test/hardhat",
    cache: "hh-cache",
    artifacts: "hh-artifacts",
  },
});
