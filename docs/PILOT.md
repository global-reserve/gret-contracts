# October 27 pilot vault

From October 27 to November 11, 2026, the project ran a GRET vault on Ethereum mainnet with its
own funds. One wallet deployed the vault, minted 1 GRET with the 11 components, synced two
components and redeemed the GRET, receiving the 11 components back. This page records those
steps and their transactions. The vault in use, deployed on November 11, 2026 with the current
source, is listed in the [README](../README.md#deployments).

## The contract

- **Address:** `GRETVault` at
  [`0x21b823334D2794a637cb9c0fd7fF8671b35F5A23`](https://etherscan.io/address/0x21b823334D2794a637cb9c0fd7fF8671b35F5A23),
  name `Global Reserve Token`, symbol `GRET`.
- **Source:** `contracts/GRETVault.sol` at commit
  [`74db71f24fcb9cf633f887f2dc26bfe60b2f0fcf`](https://github.com/global-reserve/gret-contracts/blob/74db71f24fcb9cf633f887f2dc26bfe60b2f0fcf/contracts/GRETVault.sol),
  the head of `main` when the vault was deployed. The file and the compiler settings are the
  same in every commit from `ae48b4a` through `8d4b69c`. Compiled with solc 0.8.38, the
  optimizer at 200 runs and EVM `cancun`.
- **Verification:** exact match on Sourcify (creation and runtime bytecode) and verified on
  Etherscan, both on October 27, 2026.
- **Pilot wallet:** `0xe03E228E1f1c50a985556Cc9c05b0aB953Feb7fd`, an externally owned account
  during the pilot. It deployed the vault, was its governance and its only holder, and signed
  every transaction below with MetaMask, from the local pilot page (`npm run pilot`); the two
  syncs went through a copy of that page with a `sync` button added.
- **Settings at deployment:** governance was the pilot wallet; there was no rebalancer, no
  price guard and no eligibility contract; fees were zero and minting was open.

This code is an earlier version of the vault. It kept a ledger of recognized reserves, which
the current source does not have; see [The sync](#the-sync).

## Timeline

| Date (UTC) | Step | Block | Transaction | Gas |
| --- | --- | ---: | --- | ---: |
| 2026-10-27 03:14 | Deployment | 26,281,281 | [`0x7ae2…2467`](https://etherscan.io/tx/0x7ae2271ee3d7a81c04e78137c8d5eb12cc724656231eb6fa91bcfa0b45302467) | 5,434,767 |
| 2026-10-27 03:26 | Mint of 1 GRET | 26,281,343 | [`0x9c72…ce33`](https://etherscan.io/tx/0x9c72908baa94af16a1c209cc4a340964d1f75f7d1d0fe4e7f9ae3074288ece33) | 1,154,288 |
| 2026-11-11 15:36 | `sync` of SPYx | 26,392,618 | [`0x70db…cacd`](https://etherscan.io/tx/0x70dbbce551d08de52cb2aa621eb16d1436374e6de333abe440f1628707d0cacd) | 76,220 |
| 2026-11-11 15:37 | `sync` of JAAAx | 26,392,625 | [`0x06b5…7a39`](https://etherscan.io/tx/0x06b52511f992ec81c35cc941c43bcff3cf638a6d754db9043a79be5f43457a39) | 76,220 |
| 2026-11-11 15:39 | Redemption of 1 GRET | 26,392,637 | [`0xd1e3…9f6b`](https://etherscan.io/tx/0xd1e36c28367b3c1be8a4f9417ff6477596cd763e202ddde5b657499a911e9f6b) | 532,489 |

The deployment cost 5,434,767 gas at 0.043 gwei, about 0.00023 ETH.

## The mint

Before the mint, the pilot wallet approved each of the 11 tokens for the exact amount the mint
would pull. The mint created 1 GRET for the pilot wallet and moved the amounts of
`initialAmounts()` into the vault. The vault received all of them except 1 base unit of SPYx and
1 of JAAAx: xStocks convert each amount into internal shares and round down.

At DefiLlama prices of October 22, 2026, 17:53 UTC, 1 GRET was worth about USD 100, split by the
target weights. The addresses were checked against each issuer's official sources: the seven Ondo
tokens against Ondo's token list (v13.0.0), SPYx and JAAAx against Backed's product pages, PAXG
against Paxos's repository and cbBTC against coinbase.com/cbbtc.

## The sync

The deployed vault paid redemptions from its recognized reserves: what mints had brought in, less
what redemptions had paid out. A balance above that, whatever its origin, stayed in the vault
until governance called `sync(token)`, which added it to the recognized reserves.

Between the mint and the redemption, the vault's balances of SPYx and JAAAx grew: xStocks scale
every balance by a multiplier that the issuer raises over time. Before redeeming, the pilot
wallet, as governance, synced both tokens, so that the redemption paid the whole balance:

| Token | Recognized before | Added by `sync` | Recognized after |
| --- | ---: | ---: | ---: |
| SPYx | 0.009788999999999999 | 0.000017126524662840 | 0.009806126524662839 |
| JAAAx | 0.395299999999999999 | 0.001124667928500892 | 0.396424667928500891 |

After both calls the vault had no surplus left in any component.

**`sync` is deprecated.** The current source has no `sync` and no recognized-reserve ledger:
mint, redemption and liquidation use the vault's live balances, so a balance that grows reaches
holders without any call from governance.

## The redemption

The pilot wallet called `redeem(shares, minAmountsOut, version)` of the deployed code, which pays
the caller, with all of its 1 GRET. The vault burned the GRET and sent the 11 components to the
pilot wallet:

| # | Token | Received by the vault at the mint | Returned to the pilot wallet |
| ---: | --- | ---: | ---: |
| 0 | ITOTon | 0.0447 | 0.0447 |
| 1 | SPYx | 0.009788999999999999 | 0.009806126524662839 |
| 2 | EFAon | 0.07099 | 0.07099 |
| 3 | IEMGon | 0.03256 | 0.03256 |
| 4 | SGOVon | 0.09729 | 0.09729 |
| 5 | BILon | 0.108 | 0.108 |
| 6 | JAAAx | 0.395299999999999999 | 0.396424667928500891 |
| 7 | PAXG | 0.004936 | 0.004936 |
| 8 | cbBTC | 0.00003081 | 0.00003081 |
| 9 | VNQon | 0.02658 | 0.02658 |
| 10 | DBCon | 0.2974 | 0.2974 |

Amounts are in whole tokens; cbBTC has 8 decimals and the other ten have 18. The token addresses
are in the [README](../README.md#deployments).

After the redemption the GRET supply is zero. The vault holds 1 base unit of SPYx and 1 of JAAAx,
left by xStocks rounding, and the pilot wallet is still its governance.
