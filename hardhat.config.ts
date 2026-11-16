import hardhatToolboxViemPlugin from "@nomicfoundation/hardhat-toolbox-viem";
import { configVariable, defineConfig } from "hardhat/config";

export default defineConfig({
  plugins: [hardhatToolboxViemPlugin],
  solidity: {
    profiles: {
      default: {
        version: "0.8.28",
        settings: { optimizer: { enabled: true, runs: 200 }, viaIR: true },
      },
    },
  },
  test: {
    solidity: {
      fuzz: { runs: 1000 },
      invariant: { runs: 256, depth: 50, failOnRevert: true },
    },
  },
  networks: {
    // Optional public testnet. Values are read from the Hardhat keystore
    // (`npx hardhat keystore set SEPOLIA_RPC_URL`), never from source code.
    sepolia: {
      type: "http",
      chainType: "l1",
      url: configVariable("SEPOLIA_RPC_URL"),
      accounts: [configVariable("SEPOLIA_PRIVATE_KEY")],
    },
  },
});
