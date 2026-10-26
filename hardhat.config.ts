import { createRequire } from "node:module";

import hardhatNetworkHelpers from "@nomicfoundation/hardhat-network-helpers";
import hardhatNodeTestRunner from "@nomicfoundation/hardhat-node-test-runner";
import hardhatViem from "@nomicfoundation/hardhat-viem";
import hardhatViemAssertions from "@nomicfoundation/hardhat-viem-assertions";
import { defineConfig } from "hardhat/config";

const require = createRequire(import.meta.url);

export default defineConfig({
  plugins: [hardhatViem, hardhatViemAssertions, hardhatNodeTestRunner, hardhatNetworkHelpers],
  solidity: {
    version: "0.8.38",
    path: require.resolve("solc/soljson.js"),
    preferWasm: true,
    settings: {
      optimizer: { enabled: true, runs: 200 },
      evmVersion: "cancun",
    },
    // Standard governance piece used by the integration tests; not part of the vault.
    npmFilesToBuild: ["@openzeppelin/contracts/governance/TimelockController.sol"],
  },
  test: {
    solidity: {
      profiles: {
        // `npm test`: quick enough for every change.
        default: {
          fuzz: { runs: 256 },
          invariant: { runs: 64, depth: 64 },
        },
        // `npm run test:deep`: long run before merging contract changes.
        deep: {
          fuzz: { runs: 20_000 },
          invariant: { runs: 1_000, depth: 200 },
        },
      },
    },
  },
  networks: {
    hardhat: {
      type: "edr-simulated",
      chainType: "l1",
      chainId: 31337,
    },
    localhost: {
      type: "http",
      chainType: "l1",
      chainId: 31337,
      url: "http://127.0.0.1:8545",
    },
  },
});
