# Trust Model

## Dependency Table

| Contract | What we use | What we assume | Failure mode |
|----------|-------------|----------------|--------------|
| `FungibleToken` | Vault interface, `Withdraw` entitlement, `deposit`/`withdraw`/`balance` | Standard interface behaves correctly; `balance` reflects actual holdings | Vault misreports balance: accounting diverges from reality |
| `NonFungibleToken` | NFT prize storage and transfer | Standard interface; NFTs are owned by the contract until claimed | NFT transfer fails: prize stuck in pending claims |
| `RandomConsumer` | `requestRandomness()`, `fulfillRandomRequest()` | Commit-reveal is secure; output is uniformly distributed `UInt64`; fulfillment requires 1+ block gap | Randomness unavailable: `completeDraw()` reverts, draw stuck until retry. Biased randomness: winner selection skewed |
| `Xorshift128plus` | `PRG` struct for multi-winner expansion | Correct implementation of xorshift128+; 16-byte seed produces full-period sequence | Broken PRNG: predictable or degenerate winner sequences |
| `DeFiActions` | `Sink` and `Source` interfaces for yield connector | `depositCapacity` accepts full vault balance; `withdrawAvailable` returns up to requested amount; `minimumAvailable` returns accurate balance | Yield source lies about balance: accounting drift. Yield source rejects deposit: transaction reverts. Yield source returns less than reported: deficit waterfall triggers |
| `DeFiActionsUtils` | `getEmptyVault()` utility | Returns a zero-balance vault of the correct type | Wrong vault type: type mismatch panics |
| `FlowYieldVaults` | Yield vault creation, deposit, withdraw, balance query (via connector) | Vaults honor deposit/withdraw semantics; balance query is accurate; no silent token loss | Vault paused: withdrawals fail, emergency mode triggers. Vault insolvent: deficit applied via waterfall |
| `FlowYieldVaultsClosedBeta` | `BetaBadge` for gated access to yield vaults | Badge capability remains valid for the pool's lifetime | Badge revoked: all yield source operations fail, emergency mode triggers |

## Yield Source Failures

| Scenario | Detection | Contract response |
|----------|-----------|-------------------|
| Returns less than expected on withdraw | `withdrawFromYieldVault` caps at `available`; `depositToYieldSourceFull` compares before/after balance | Slippage event emitted. For deposits: asserts `actualReceived > 0`. For partial withdraw: deficit detected on next `syncWithYieldSource()` |
| Balance reports 0 unexpectedly | `syncWithYieldSource()` computes deficit = `allocatedFunds - 0` | Full deficit waterfall: protocol fee absorbed first, then prize pool, then share price reduced. `InsolvencyDetected` event if deficit exceeds all buffers |
| Yield source unavailable (reverts) | Transaction that calls yield source reverts | Deposits/withdrawals fail. Admin can enable emergency mode manually, or auto-trigger fires based on `maxWithdrawFailures` and `minYieldSourceHealth` thresholds |
| Returns 0 on deposit (accepts tokens, credits nothing) | `depositToYieldSourceFull` asserts `actualReceived > 0` | Transaction reverts. No state change. User's tokens are returned |
| Gradual balance decay (e.g., negative yield) | Detected on next `syncWithYieldSource()` call | Deficit waterfall: protocol fee -> prize pool -> share price. Losses socialized proportionally across all depositors via share price decrease |

The deficit waterfall order is hardcoded and independent of the distribution strategy: protocol fee is consumed first, prize pool second, user rewards (share price) last.

## Adversarial Model

| Actor | What they CAN do | What they CANNOT do |
|-------|------------------|---------------------|
| **User** | Deposit, withdraw, claim prizes, register/unregister from pools. Time deposits to maximize TWAB for a given capital outlay | Withdraw more than their share balance. Manipulate share price (virtual offset prevents inflation attack). Unregister during an active draw. Deposit below `minimumDeposit` or above `SAFE_MAX_TVL`. Affect other users' share balances or TWAB |
| **Admin (ConfigOps)** | Update draw intervals, process rewards batches, manage bonus weights, set emergency config, cleanup stale entries | Start/complete draws, create/destroy pools, change distribution strategy, enable emergency mode, set protocol fee recipient |
| **Admin (CriticalOps)** | All ConfigOps actions plus: create pools, start/complete draws, change distribution strategy, enable/disable emergency mode, force state transitions | Set protocol fee recipient (requires `OwnerOnly`). Directly access user funds. Bypass share accounting. Mint shares without deposits |
| **Account Owner (OwnerOnly)** | Set protocol fee recipient address, withdraw unclaimed protocol fees | Delegate this entitlement via capability (enforced by design: `OwnerOnly` is never issued as a capability) |
| **Sponsor** | Deposit funds (lottery-ineligible), withdraw funds | Participate in draws. Earn prizes. Affect registered users' TWAB or weights |
| **Validator/Miner** | Observe pending transactions in mempool | Predict randomness output before commit block is finalized (Flow consensus model). Selectively withhold blocks to influence `RandomConsumer` output |
| **Yield source operator** | Pause the vault, change yield rates, become insolvent | Directly access PrizeLinkedAccounts state. Mint or burn shares. The connector holds the entitled capability internally; the yield source contract never receives it |
