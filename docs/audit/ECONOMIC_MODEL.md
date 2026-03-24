# Economic Model

## 1. Token Flow

```
User Deposit
    |
    v
Pool.deposit()  ──sync──>  Yield Source (DeFiActions connector)
    |                            |
    | (mint shares)              | (accrues yield over time)
    v                            v
ShareTracker                syncWithYieldSource()
                                 |
                    ┌────────────┼────────────────┐
                    v            v                 v
              [Rewards]    [Prize Yield]    [Protocol Fee]
                    |            |                 |
                    v            v                 v
             Share price ↑   allocatedPrizeYield  allocatedProtocolFee
             (all users)     (stays in yield       (stays in yield
                              source until          source until
                              completeDraw)         startDraw)
                                 |                 |
                                 v                 v
                           completeDraw()     startDraw()
                           auto-compound      forward to recipient
                           into winner         or unclaimed vault
                           deposits
```

All funds remain in the yield source until draw time. `allocatedPrizeYield` and `allocatedProtocolFee` are accounting entries, not separate vaults.

## 2. Three-Way Split

Controlled by `DistributionStrategy` (currently `FixedPercentageStrategy`). Applied in `applyExcess()` (line 3971) during `syncWithYieldSource()`.

| Category | Destination | Who Benefits | When Transferred |
|----------|------------|--------------|------------------|
| Rewards | `shareTracker.accrueYield()` -- increases `totalAssets`, raising share price | All depositors (users + sponsors) proportionally | Immediately during sync |
| Prize | `allocatedPrizeYield` counter | Draw winners (users only, not sponsors) | `completeDraw()` auto-compounds into winner shares |
| Protocol Fee | `allocatedProtocolFee` counter | Protocol operator | `startDraw()` withdraws and forwards to recipient or unclaimed vault |

`FixedPercentageStrategy` calculates: `rewards = total * rewardsPercent`, `prize = total * prizePercent`, `protocolFee = total - rewards - prize` (remainder assignment absorbs UFix64 rounding).

Virtual share dust from rewards accrual (absorbed by the `VIRTUAL_SHARES` offset) is redirected to protocol fee.

Minimum distribution threshold: `0.0001` (100x minimum UFix64). Amounts below this accumulate in the yield source until the next sync exceeds the threshold.

## 3. Sponsor vs User

| Property | User (PoolPositionCollection) | Sponsor (SponsorPositionCollection) |
|----------|------------------------------|-------------------------------------|
| Share accounting | Yes (ShareTracker) | Yes (ShareTracker) |
| Share price appreciation | Yes (rewards portion) | Yes (rewards portion) |
| TWAB tracking | Yes (per-round weight) | No |
| Prize eligibility | Yes (registered in `registeredReceiverList`) | No (tracked in `sponsorReceivers` map) |
| Bonus weights | Yes | No |
| Deposit state rules | Normal: min deposit. Partial: capped. Emergency/Paused: blocked. | Same rules |
| Withdrawal | Always allowed except Paused | Always allowed except Paused |
| Unregistration on 0 shares | Removed from `registeredReceiverList` (if no draw active) | Removed from `sponsorReceivers` |

Both user and sponsor shares use the same `ShareTracker` instance. A sponsor deposit increases `totalShares` and `totalAssets` identically to a user deposit. The only difference is prize eligibility.

## 4. Deficit Handling (Loss Waterfall)

When `syncWithYieldSource()` detects `yieldBalance < allocatedFunds`, `applyDeficit()` (line 4059) runs a deterministic waterfall. The waterfall is independent of the distribution strategy percentages.

| Priority | Absorber | Effect | Rationale |
|----------|----------|--------|-----------|
| 1st | `allocatedProtocolFee` | Reduced (protocol takes first loss) | Protocol can absorb operational losses |
| 2nd | `allocatedPrizeYield` | Reduced (smaller prize pool) | Prize is discretionary, not principal |
| 3rd | Rewards (`shareTracker.decreaseTotalAssets`) | Share price decreases for all depositors | User principal is last resort |

If all three are exhausted and deficit remains: `InsolvencyDetected` event emitted. The unreconciled amount represents a permanent loss.

Invariant after sync: `userPoolBalance + allocatedPrizeYield + allocatedProtocolFee == yieldSourceBalance`

## 5. References

- Share price math (virtual offset, ERC4626 model): [`docs/ACCOUNTING.md`](../ACCOUNTING.md)
- TWAB mechanics (normalized weight, round duration): [`docs/TWAB.md`](../TWAB.md)
- Main contract: `cadence/contracts/PrizeLinkedAccounts.cdc`
