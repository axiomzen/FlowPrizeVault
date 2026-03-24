# Contract Review Notes — PrizeLinkedAccounts (Cadence)

> **Goal:** Provide enough context so a reviewer can understand intent, design decisions, and security assumptions quickly.
> Detailed breakdowns for each section are in [`docs/audit/`](audit/README.md).

## 1) TL;DR (3-6 sentences)
**What does this contract do?**
No-loss lottery protocol on Flow. Users deposit fungible tokens into a pool; deposits are forwarded to an external yield source. Yield is split three ways: savings (share price appreciation), prize pool (lottery), and protocol fee. Winners are selected via TWAB-weighted on-chain randomness each round.

**Why does it exist?**
Prize-linked savings product — users earn guaranteed yield while having chances to win lottery prizes funded by aggregated yield. No depositor loses principal.

**Core user flows (happy path):**
1. Create `PoolPositionCollection` → deposit tokens → earn yield via share price increase → win prizes → withdraw anytime
2. Sponsors: create `SponsorPositionCollection` → deposit for yield only (no prize eligibility) → withdraw anytime

**Each round, admin/automation runs:**
1. `startDraw` → `processDrawBatch` (repeat until complete) → `completeDraw` → `startNextRound`
2. Winners receive prizes automatically; no user action required to claim yield-based prizes

---

## 2) Scope
**In scope (this contract is responsible for):**
- `cadence/contracts/PrizeLinkedAccounts.cdc` (~5,900 lines) — pools, shares, TWAB, draws, positions, admin, emergency
- `cadence/contracts/FlowYieldVaultsConnectorV2.cdc` — yield source connector for EVM-bridged PYUSD tokens

**Out of scope (explicitly not handled here):**
- `FungibleToken`, `NonFungibleToken` — Flow framework standards
- `RandomConsumer`, `Xorshift128plus` — Flow randomness primitives
- `DeFiActions`, `DeFiActionsUtils` — yield source interface (external)
- `FlowYieldVaults`, `FlowYieldVaultsClosedBeta` — yield protocol (external)

---

## 3) Key Cadence Concepts Used

- **Resources:** Admin (1, deployer account), Pool (contract dict), PoolPositionCollection (user account), SponsorPositionCollection (user account), PrizeDistributor (nested in Pool), PrizeDrawReceipt + BatchSelectionData (ephemeral, during draws only)
- **Interfaces:** `DistributionStrategy` (yield split), `PrizeDistribution` (winner selection) — both struct interfaces with concrete implementations (`FixedPercentageStrategy`, `SingleWinnerPrize`, `PercentageSplit`)
- **Capabilities:** Public read-only capabilities for both collection types. Admin capabilities scoped by entitlement (ConfigOps, CriticalOps). OwnerOnly never issued as capability.
- **Storage paths:** 3 storage paths (user collection, sponsor collection, admin) + 2 public paths (read-only queries). No private paths (Cadence 1.0).
- **Events:** 42 event types across 7 categories. See [EVENT_CATALOG](audit/EVENT_CATALOG.md).
- **Auth patterns:** 4 entitlements (ConfigOps, CriticalOps, OwnerOnly, PositionOps). Draw functions (`startDraw`, `processDrawBatch`, `completeDraw`) are permissionless at contract level. `startNextRound` requires ConfigOps.

---

## 4) Actors & Permissions

| Actor | Entitlement | What They Can Do | Access Enforcement |
|-------|------------|------------------|-------------------|
| User | `PositionOps` | Deposit, withdraw, claim NFT prizes | Capability from stored `PoolPositionCollection` |
| Sponsor | `PositionOps` | Deposit, withdraw (no prize eligibility) | Capability from stored `SponsorPositionCollection` |
| Config Admin | `ConfigOps` | Draw intervals, min deposit, bonus weights, NFT prizes, cleanup, start next round | Capability with `ConfigOps` from stored `Admin` |
| Critical Admin | `CriticalOps` | Create pools, strategies, emergency mode, draw phases, direct funding, protocol fee withdrawal | Capability with `CriticalOps` from stored `Admin` |
| Owner | `OwnerOnly` | Set protocol fee recipient | Storage borrow only — never issued as capability |
| Anyone | none | `startDraw()`, `processDrawBatch()`, `completeDraw()`, all view functions | Contract-level `access(all)` with internal guards |

---

## 5) Storage Layout & Capability Surface

| Path | Type | What's There | Access |
|------|------|-------------|--------|
| `/storage/PrizeLinkedAccountsCollection` | Storage | `PoolPositionCollection` | Owner (UUID = receiverID) |
| `/public/PrizeLinkedAccountsCollection` | Public | Read-only capability | Anyone — balance queries, entry counts |
| `/storage/PrizeLinkedAccountsSponsorCollection` | Storage | `SponsorPositionCollection` | Owner |
| `/public/PrizeLinkedAccountsSponsorCollection` | Public | Read-only capability | Anyone — balance queries |
| `/storage/PrizeLinkedAccountsAdmin` | Storage | `Admin` | Deployer only — no public capability |

**Resource lifecycle:**
- **Creation:** Collections via `createPoolPositionCollection()` / `createSponsorPositionCollection()` (access(all)). Admin created once in contract `init()`. Pools via `Admin.createPool()`.
- **Movement:** Tokens flow: user vault -> pool -> yield source (deposit) and reverse (withdraw). NFTs flow: admin -> pool prize storage -> pending claims -> user.
- **Destruction:** No explicit destroy paths for pools or admin. If a user destroys their `PoolPositionCollection`, funds keyed to that UUID become permanently inaccessible (by design, no recovery mechanism).

---

## 6) Trust Assumptions
**We trust:**
- Flow framework contracts (FungibleToken, NonFungibleToken, RandomConsumer) — standard behavior
- Xorshift128plus — correct PRNG implementation with full 2^128 state space (PR #53 fixed seed expansion)
- The yield source connector provided at pool creation — immutable after `createPool()`

**We do NOT trust (assume adversarial):**
- Arbitrary users / transaction submitters — constrained by entitlements, TWAB, minimum deposits. Note: draw functions (`startDraw`, `processDrawBatch`, `completeDraw`) are `access(all)`; they are permissionless by design, protected by internal state guards rather than entitlements.

**External dependencies:**

| Contract | What We Assume | Failure Mode |
|----------|---------------|--------------|
| `FungibleToken` | Vault balances are accurate | Accounting diverges |
| `NonFungibleToken` | Standard transfer semantics | Prize stuck in pending claims |
| `RandomConsumer` | Uniform `UInt64` output, commit-reveal secure | Draw reverts or skewed selection |
| `DeFiActions` | `minimumAvailable()` accurate, deposits/withdrawals honored | Deficit waterfall triggers; emergency mode if repeated |
| `FlowYieldVaults` | Vault solvent, operations functional | Emergency auto-trigger on health score drop |
| `FlowYieldVaultsClosedBeta` | BetaBadge remains valid | All yield source ops fail |

See [TRUST_MODEL](audit/TRUST_MODEL.md) for full analysis.

---

## 7) Key Invariants (must always be true)

| # | Invariant | How To Try To Break It |
|---|-----------|----------------------|
| 1 | `userPoolBalance + allocatedPrizeYield + allocatedProtocolFee == yieldSourceBalance` (post-sync) | Skip sync (all mutating paths call it). Manipulate yield source's `minimumAvailable()`. |
| 2 | `normalizedWeight <= shares` (TWAB safety cap) | Cause `actualDuration == 0` or rounding to exceed shares. Capped in `finalizeTWAB()`. |
| 3 | `sharePrice = (totalAssets + 0.0001) / (totalShares + 0.0001)` | Division by zero impossible (virtual offset). Donate assets without minting shares to inflate — limited to ~0.0001% impact. |
| 4 | `sum(userShares) == totalShares` | Bug in share arithmetic. Dust threshold burns could create mismatch if `minimumDeposit` were 0. |
| 5 | `withdrawal <= yieldSource.minimumAvailable()` | Yield source lies about availability. Handled: returns empty vault on failure. |
| 6 | No unregistration during active draw batch | Withdraw to 0 during batch — user becomes ghost (0-weight, cleaned up after draw). |
| 7 | Valid state transitions only | `setPoolState()` admin override can transition any -> any by design. |
| 8 | `actualEndTime >= targetEndTime` | Only set by `startDraw()` which requires `canDrawNow()`. `setTargetEndTime()` asserts `newTarget >= now`. |

See [INVARIANTS](audit/INVARIANTS.md) for enforcement locations and line references.

---

## 8) Critical Functions / Hot Paths

| Function | Access | What Could Go Wrong |
|----------|--------|---------------------|
| `deposit` | `PositionOps` | Yield source silently swallows tokens (mitigated: asserts `actualReceived > 0`). Slippage bypass if yield source inflates `minimumAvailable()` post-deposit. |
| `withdraw` | `PositionOps` | Returns empty vault on liquidity failure (no revert). Consecutive failures auto-trigger emergency. Ghost entries if withdraw-to-0 during draw. |
| `startDraw` | `access(all)` | Reverts if `allocatedPrizeYield == 0`. Force-unwrap on `activeRound` guarded by precondition. Requests randomness (must wait 1+ block for `completeDraw`). |
| `processDrawBatch` | `access(all)` | Snapshot count freezes receiver list at `startDraw()`. Weight overflow asserted per entry. |
| `completeDraw` | `access(all)` | PercentageSplit rounding overflow (fixed PR #55). PRNG seed was degenerate (fixed PR #53). Same-block call panics (randomness requires 1+ block gap). |
| `syncWithYieldSource` | `access(contract)` | Trusts external `minimumAvailable()`. Manipulated yield source can fabricate excess or deficit. |
| `setProtocolFeeRecipient` | `OwnerOnly` | Redirects all future protocol fees. Invalid capability silently routes to unclaimed vault. |
| `withdrawUnclaimedProtocolFee` | `CriticalOps` | TOCTOU force-unwrap (fixed PR #56). Capped at available balance. |
| `updatePoolDistributionStrategy` | `CriticalOps` | Takes effect immediately on next sync. Mid-round change alters yield split without retroactive adjustment. |

See [CRITICAL_FUNCTIONS](audit/CRITICAL_FUNCTIONS.md) for full table with preconditions.

---

## 9) Known Risks / Tradeoffs

| Risk | Severity | Mitigation |
|------|----------|------------|
| Malicious yield connector steals deposited funds | Critical | Connector is immutable after pool creation (`let yieldConnector`). `createPool` requires `CriticalOps`. |
| Admin key compromise redirects protocol fees | High | `setProtocolFeeRecipient` requires `OwnerOnly` (never delegated as capability). Multi-sig recommended. |
| Yield source `minimumAvailable()` manipulated | High | `syncWithYieldSource` trusts this value. Fabricated excess inflates rewards; fabricated deficit socializes phantom losses. |
| `PoolPositionCollection` destroyed → funds inaccessible | High | By design (resource ownership). No admin recovery mechanism. |
| Admin changes prize distribution during active draw | Medium | No lock between `startDraw` and `completeDraw`. Change alters winner count/splits for current draw. |
| `startDraw` blocks if no yield accrued | Medium | Asserts `allocatedPrizeYield > 0`. Admin must `fundPoolDirect(destination: .Prize)` to unblock. |
| UFix64 precision loss at scale | Low | Virtual offset absorbs dust. Protocol fee gets remainder in `FixedPercentageStrategy`. Last winner gets remainder in `PercentageSplit`. |
| Contract size (5,900+ lines) | Low | Maintenance/upgrade risk. No decomposition planned. |

See [RISK_ANALYSIS](audit/RISK_ANALYSIS.md) for DoS vectors and recently fixed bugs (PRs #53, #55, #56).

---

## 10) Testing & Emulator Workflows
**Cadence tests present:**
36 fast test files + 1 long-running stress test covering: TWAB, draws, deposits/withdrawals, shares, emergency states, NFT prizes, batch processing, state machines, precision, distribution strategies, slippage, bonus weights, sponsor deposits, and more. See [TESTING_GUIDE](audit/TESTING_GUIDE.md) for complete file list.

**Emulator workflows available:**
```bash
make test          # Fast tests (~36 files)
make test-all      # Fast + long-running stress tests
make test-long     # Stress tests only
make test-cover    # Fast tests with coverage
flow test cadence/tests/RoundTWAB_test.cdc  # Single file
```

**What's not covered / needs reviewer attention:**
- No fuzz testing for PRNG distribution uniformity
- No test for `PoolPositionCollection` resource destruction
- No concurrent multi-pool operation tests
- No adversarial deposit-before-`startDraw` timing test
- No gas/computation limit testing for large batch processing
- Limited stress testing (1 long test file)

---

## 11) Review Checklist (Author)

### Code Quality & Style
- [ ] Code follows the project style guide
- [ ] Code is clearly documented (file-level, public functions, non-obvious logic)
- [ ] Code follows Cadence design patterns
  https://cadence-lang.org/docs/design-patterns
- [ ] Code avoids known Cadence anti-patterns
  https://cadence-lang.org/docs/anti-patterns
- [ ] Code follows project development standards
  https://cadence-lang.org/docs/project-development-tips

### Security & Correctness
- [ ] Code follows Cadence security best practices
  https://cadence-lang.org/docs/security-best-practices
- [ ] Capability surface reviewed (public vs storage exposure is intentional)
- [ ] Resource lifecycle reviewed (no unintended duplication or loss)
- [ ] Invariants listed above reflect the current implementation
- [ ] All `access(all)` functions verified to not expose unintended mutation
- [ ] All force-unwrap (`!`) and forced-cast (`as!`) usage verified safe

### Tooling & Tests
- [ ] Cadence tests exist and pass
  https://cadence-lang.org/docs/testing-framework
- [ ] Emulator workflows exist and run successfully
- [ ] Cadence linter run and feedback addressed
  https://developers.flow.com/build/tools/flow-cli/lint
  *(Also available via the Cadence VS Code extension)*

### Final Checks
- [ ] No debug code, TODOs, or commented-out logic in critical paths
- [ ] This document matches the current commit: `c7a9d06`

---

## 12) Links
- **PR:** TBD
- **Contract locations:**
  - `cadence/contracts/PrizeLinkedAccounts.cdc` (main contract)
  - `cadence/contracts/FlowYieldVaultsConnectorV2.cdc` (yield connector)
- **Deployment info:**
  - Emulator: `f8d6e0586b0a20c7` (Development)
  - Testnet: [`839535ddeb5acf17`](https://contractbrowser.com/account/0x839535ddeb5acf17) (Testing)
  - Mainnet: [`a092c4aab33daeda`](https://contractbrowser.com/account/0xa092c4aab33daeda) (Pending Audit)
- **Related specs/docs:**
  - [docs/ACCOUNTING.md](ACCOUNTING.md) — Share price math, ERC4626 model, virtual offset
  - [docs/TWAB.md](TWAB.md) — Time-weighted average balance mechanics
  - [docs/audit/](audit/README.md) — Full audit documentation package (14 documents)
- **Recently fixed bugs:**
  - PR #53 — PRNG seed expansion (2^64 → 2^128 state space)
  - PR #55 — PercentageSplit rounding overflow (could brick `completeDraw`)
  - PR #56 — TOCTOU force-unwrap in `withdrawUnclaimedProtocolFee`
