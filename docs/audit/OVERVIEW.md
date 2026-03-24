# PrizeLinkedAccounts -- Audit Overview

## What It Does

PrizeLinkedAccounts is a no-loss lottery protocol on Flow. Users deposit fungible tokens into a pool; deposits are forwarded to an external yield source. Yield is split three ways: savings (share price appreciation), prize pool (lottery), and protocol fee. Winners are selected via TWAB-weighted on-chain randomness each round. Prizes auto-compound into the winner's deposit -- no token transfer occurs.

## Scope

| File | Responsibility | In Scope |
|------|---------------|----------|
| `cadence/contracts/PrizeLinkedAccounts.cdc` (~5900 lines) | Main contract: pools, shares, TWAB, draws, positions, admin | Yes |
| `cadence/contracts/FlowYieldVaultsConnectorV2.cdc` | Yield source connector (EVM-bridged tokens, 6-decimal truncation) | Yes |
| `cadence/contracts/DeFiActions.cdc` (imported) | Interface for yield source Sink/Source | Out -- external dependency |
| `cadence/contracts/RandomConsumer.cdc` (imported) | Flow on-chain randomness | Out -- Flow framework |
| `cadence/contracts/Xorshift128plus.cdc` (imported) | PRNG for multi-winner selection | Out -- external dependency |
| `cadence/contracts/FungibleToken.cdc` (imported) | Flow FT standard | Out -- Flow framework |
| `cadence/contracts/NonFungibleToken.cdc` (imported) | Flow NFT standard | Out -- Flow framework |

## User Flows

### 1. User Deposit

1. User creates `PoolPositionCollection`, stores at `PoolPositionCollectionStoragePath`.
2. User calls `collection.deposit(poolID, vault, maxSlippageBps)` with `PositionOps` entitlement.
3. Pool checks emergency state, minimum deposit, TVL cap.
4. Pool syncs with yield source (materializes pending yield/deficit).
5. Tokens forwarded to yield source; slippage check against `maxSlippageBps`.
6. ShareTracker mints shares proportional to actual received amount.
7. Active Round records TWAB share change.
8. `userPoolBalance` incremented.

### 2. User Withdrawal

1. User calls `collection.withdraw(poolID, amount)` with `PositionOps` entitlement.
2. Pool checks not paused; attempts auto-recovery if in emergency mode.
3. Syncs yield source in normal mode.
4. Validates balance; applies dust threshold (1/10 of minimum deposit).
5. Checks yield source liquidity. On failure: emits event, may trigger emergency mode, returns empty vault.
6. Withdraws from yield source; burns shares; updates TWAB; decrements `userPoolBalance`.
7. If shares reach 0 and no active draw, unregisters receiver (swap-and-pop).

### 3. Sponsor Deposit

1. User creates `SponsorPositionCollection`, stores at `SponsorPositionCollectionStoragePath`.
2. Calls `collection.deposit(poolID, vault, maxSlippageBps)` with `PositionOps` entitlement.
3. Same yield source deposit and share minting as regular deposit.
4. Receiver marked in `sponsorReceivers` map -- excluded from `registeredReceiverList`.
5. No TWAB tracking. Sponsor earns rewards yield but cannot win prizes.

### 4. Draw Cycle (3 phases + round start)

1. **startDraw()** -- permissionless when round target time passed. Syncs yield, sets `actualEndTime` on active round, snapshots receiver count, materializes protocol fee, requests randomness, stores `PrizeDrawReceipt`.
2. **processDrawBatch(limit)** -- permissionless, called repeatedly. For each receiver: finalizes TWAB, adds bonus weight, builds cumulative weight array in `BatchSelectionData`. Skips sponsors.
3. **completeDraw()** -- permissionless after batch complete + 1 block. Fulfills randomness, selects winners via binary search on cumulative weights, distributes prizes as auto-compounded share deposits. Destroys active round; pool enters intermission.
4. **startNextRound()** -- admin (ConfigOps). Creates new `Round` resource with configured interval. Exits intermission.

### 5. NFT Prize Claim

1. Admin deposits NFT via `admin.depositNFTPrize(poolID, nft)`.
2. During `completeDraw()`, NFTs assigned per `PrizeDistribution` config.
3. Won NFTs moved from `nftPrizes` to `pendingNFTClaims[receiverID]`.
4. Winner calls `collection.claimPendingNFT(poolID, nftIndex)` with `PositionOps` entitlement.
5. NFT resource returned to caller.

## Actors

| Actor | Entitlement | Capabilities | Access Enforcement |
|-------|------------|-------------|-------------------|
| User | `PositionOps` | deposit, withdraw, claimPendingNFT, read balances | Capability issued from stored `PoolPositionCollection`; `access(PositionOps)` on mutating functions |
| Sponsor | `PositionOps` | deposit, withdraw, read balances (no prize eligibility) | Capability issued from stored `SponsorPositionCollection`; `access(PositionOps)` on mutating functions |
| Config Admin | `ConfigOps` | draw intervals, minimum deposit, bonus weights, NFT prizes, cleanup, process rewards, start next round | Capability with `ConfigOps` entitlement from stored `Admin` resource |
| Critical Admin | `CriticalOps` | create pools, strategies, emergency mode, draw phases, direct funding, withdraw protocol fee | Capability with `CriticalOps` entitlement from stored `Admin` resource |
| Owner | `OwnerOnly` | set protocol fee recipient | Direct `auth(OwnerOnly)` storage borrow only; capability MUST NOT be issued with this entitlement |
| Anyone | none | `startDraw()`, `processDrawBatch()`, `completeDraw()`, all `view` functions, `borrowPool()` | Contract-level `access(all)` functions; pool state preconditions enforced internally |
