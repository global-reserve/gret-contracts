import type { Address } from "viem";

/**
 * Parameters of the mainnet pilot, decided on 20 October 2026.
 *
 * A deployment fixes them for that vault: the components, the basket of the first GRET and the
 * initial governance, which can later be handed over in two steps with the vault's 7-day wait.
 *
 * Addresses checked on 20 October 2026: the seven Ondo tokens against Ondo's official token list
 * (v13.0.0), SPYx and JAAAx against Backed's product pages, PAXG against Paxos's repository, and
 * cbBTC against coinbase.com/cbbtc, confirmed by hand by the project owner.
 *
 * `perGret` gives 1 GRET worth about USD 100, split by the target weights of 22 October 2026, at the
 * DefiLlama prices of 22 October 2026, 17:53 UTC (`priceUsd`, for reference only).
 */
export const PILOT_WALLET: Address = "0xe03E228E1f1c50a985556Cc9c05b0aB953Feb7fd";

export const PILOT = {
  /** Deploys, governs and makes the first mint. Deploying gives no power over the vault. */
  wallet: PILOT_WALLET,
  governance: PILOT_WALLET,
  pricedAt: "2026-10-22T17:53Z",
  components: [
    { symbol: "ITOTon", address: "0x0692481c369e2bdc728a69ae31b848343a4567be", decimals: 18, weightPct: 7.5, priceUsd: 167.8, perGret: "0.0447" },
    { symbol: "SPYx", address: "0x90a2a4c76b5d8c0bc892a69ea28aa775a8f2dd48", decimals: 18, weightPct: 7.5, priceUsd: 766.15, perGret: "0.009789" },
    { symbol: "EFAon", address: "0x4111b60bc87f2bd1e81e783e271d7f0ec6ee088b", decimals: 18, weightPct: 7.5, priceUsd: 105.65, perGret: "0.07099" },
    { symbol: "IEMGon", address: "0xcdd60d15125bf3362b6838d2506b0fa33bc1a515", decimals: 18, weightPct: 2.5, priceUsd: 76.77, perGret: "0.03256" },
    { symbol: "SGOVon", address: "0x8de5d49725550f7b318b2fa0f1b1f118e98e8d0f", decimals: 18, weightPct: 10, priceUsd: 102.78, perGret: "0.09729" },
    { symbol: "BILon", address: "0x2710e30d84b376c34a3b3036aa196b26a83a321b", decimals: 18, weightPct: 10, priceUsd: 92.6, perGret: "0.108" },
    { symbol: "JAAAx", address: "0x3bf2e3be4a829bb3a5f5be450ae4c8eb3488da71", decimals: 18, weightPct: 20, priceUsd: 50.6, perGret: "0.3953" },
    { symbol: "PAXG", address: "0x45804880de22913dafe09f4980848ece6ecbaf78", decimals: 18, weightPct: 20, priceUsd: 4051.64, perGret: "0.004936" },
    { symbol: "cbBTC", address: "0xcbb7c0000ab88b473b1f5afd9ef808440eed33bf", decimals: 8, weightPct: 2.5, priceUsd: 81150.78, perGret: "0.00003081" },
    { symbol: "VNQon", address: "0xccae8843e26259278c200c6506f6e5a3bdd524cd", decimals: 18, weightPct: 2.5, priceUsd: 94.06, perGret: "0.02658" },
    { symbol: "DBCon", address: "0x20224080ad516769723c9a4a18325fc4e8c9ab5d", decimals: 18, weightPct: 10, priceUsd: 33.63, perGret: "0.2974" },
  ],
} as const;

/**
 * Chainlink feeds for the price guard (`contracts/ChainlinkPriceGuard.sol`), proposed on 26 October
 * 2026 and checked that day against Chainlink's mainnet feed directory and on chain. Each feed
 * quotes one whole token in US dollars: Chainlink's "Calculated" feeds for Ondo tokens already
 * include Ondo's multiplier, and one SPYx is one SPY share (its multiplier only turns internal
 * shares into balance). The other six components have no Ethereum feed today, so the guard cannot
 * price them and the vault cannot swap them. The guard is deployed only when rebalancing starts.
 *
 * `maxAge` is each feed's 24-hour heartbeat plus one hour. The equity feeds follow US market hours
 * (24/5): on weekends their prices go stale and swaps of those tokens stop.
 */
export const PRICE_FEEDS = [
  { symbol: "SPYx", description: "SPY-USD (24/5)", feed: "0x25efbA0d9b115D233cfA849F16BA743E8FFba2a1", maxAge: 90_000 },
  {
    symbol: "SGOVon",
    description: "SGOVon / USD (Calculated)",
    feed: "0xfE45662E9fA552464289B0568D4A846c6F284Db9",
    maxAge: 90_000,
  },
  { symbol: "BILon", description: "BILon-USD (Calculated)", feed: "0x254599afD7f9F3f18775fC24693Ba0d1cE8A4Ac6", maxAge: 90_000 },
  { symbol: "PAXG", description: "PAXG / USD", feed: "0x9944D86CEB9160aF5C5feB251FD671923323f8C3", maxAge: 90_000 },
  { symbol: "cbBTC", description: "cbBTC / USD", feed: "0x2665701293fCbEB223D11A08D826563EDcCE423A", maxAge: 90_000 },
] as const satisfies readonly { symbol: string; description: string; feed: Address; maxAge: number }[];
