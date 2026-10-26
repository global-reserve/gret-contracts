import type { ContractReturnType } from "@nomicfoundation/hardhat-viem/types";
import { network } from "hardhat";
import { formatUnits, parseUnits } from "viem";

// Mocks with the symbols and decimals of the reference basket. They do not model the real
// tokens or their issuer restrictions.
const BASKET = [
  { symbol: "ITOTon", decimals: 18 },
  { symbol: "SPYx", decimals: 18 },
  { symbol: "EFAon", decimals: 18 },
  { symbol: "IEMGon", decimals: 18 },
  { symbol: "SGOVon", decimals: 18 },
  { symbol: "BILon", decimals: 18 },
  { symbol: "JAAAx", decimals: 18 },
  { symbol: "PAXG", decimals: 18 },
  { symbol: "cbBTC", decimals: 8 },
  { symbol: "VNQon", decimals: 18 },
  { symbol: "DBCon", decimals: 18 },
] as const;

// Placeholder: one whole unit of each component per GRET. The real quantities are still to be
// decided and cannot be derived from the dollar weights without prices.
const PLACEHOLDER_UNITS = "1";

const connection = await network.create();

try {
  const { viem } = connection;
  const publicClient = await viem.getPublicClient();

  if ((await publicClient.getChainId()) !== 31337) {
    throw new Error("The test deployment only runs on the local network (chainId 31337).");
  }

  // Hardhat test account #1 stands in for the governance contract, still to be defined.
  const [deployer, governance] = await viem.getWalletClients();

  const components: ContractReturnType<"MockERC20">[] = [];
  for (const { symbol, decimals } of BASKET) {
    components.push(await viem.deployContract("MockERC20", [`Mock ${symbol}`, symbol, decimals]));
  }
  const initialAmounts = BASKET.map(({ decimals }) => parseUnits(PLACEHOLDER_UNITS, decimals));

  const vault = await viem.deployContract("GRETVault", [
    components.map((component) => component.address),
    initialAmounts,
    governance.account.address,
  ]);

  for (const [i, component] of components.entries()) {
    await component.write.mint([deployer.account.address, initialAmounts[i]]);
    await component.write.approve([vault.address, initialAmounts[i]]);
  }
  const shares = await vault.read.INITIAL_SHARES();
  // The first mint issues exactly INITIAL_SHARES, so that is also the minimum.
  await vault.write.mint([shares, initialAmounts, shares, await vault.read.basketVersion()]);

  const reserves = await vault.read.reserves();
  console.table(
    BASKET.map(({ symbol, decimals }, i) => ({
      symbol,
      decimals,
      address: components[i].address,
      reserve: formatUnits(reserves[i], decimals),
    })),
  );
  console.table([
    { contract: "GRETVault", address: vault.address },
    { contract: "governance (placeholder)", address: governance.account.address },
  ]);
  console.log(`GRET supply: ${formatUnits(await vault.read.totalSupply(), 18)}`);
} finally {
  await connection.close();
}
