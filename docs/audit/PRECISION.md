# Precision and Rounding

## UFix64 Constraints

| Property | Value |
|----------|-------|
| Type | Unsigned fixed-point |
| Decimal places | 8 (smallest unit: 0.00000001) |
| Range | 0.0 to 184,467,440,737.09551615 |
| Negatives | Not representable; subtraction underflows panic |
| Overflow | Addition/multiplication beyond max panics at runtime |
| Division by zero | Panics at runtime |

Cadence has no signed fixed-point type. All deficit/loss logic must track direction explicitly and guard every subtraction against underflow.

## Virtual Offset

Protects against the ERC4626 inflation attack where the first depositor manipulates share price by donating assets before others deposit.

```
sharePrice = (totalAssets + VIRTUAL_ASSETS) / (totalShares + VIRTUAL_SHARES)

convertToShares(assets) = assets / sharePrice
convertToAssets(shares) = shares * sharePrice
```

| Constant | Value | Purpose |
|----------|-------|---------|
| `VIRTUAL_SHARES` | 0.0001 | Dead shares that anchor price near 1.0 |
| `VIRTUAL_ASSETS` | 0.0001 | Dead assets paired with dead shares |

**Dust created**: Virtual shares receive a fraction of every yield accrual. The contract calculates this explicitly:

```
dustAmount = yieldAmount * VIRTUAL_SHARES / (totalShares + VIRTUAL_SHARES)
actualRewards = yieldAmount - dustAmount
```

Dust is routed to `allocatedProtocolFee` via `RewardsRoundingDustToProtocolFee` event. At typical TVL (>1000 tokens), dust per accrual is < 0.0000001 tokens.

## Rounding

| Operation | Direction | Who benefits | Worst case per call |
|-----------|-----------|--------------|---------------------|
| `convertToShares` (deposit) | Truncate down | Protocol (fewer shares minted) | 1 unit (0.00000001) |
| `convertToAssets` (view balance) | Truncate down | Protocol (lower reported balance) | 1 unit |
| `FixedPercentageStrategy.calculateDistribution` | Protocol gets remainder | Protocol | Sum of rewards+prize rounding errors |
| `PercentageSplit.distributePrizes` | Last winner gets remainder | Last winner | Sum of prior winners' rounding errors |
| `FixedAmountTiers.distributePrizes` | Exact fixed amounts | N/A (exact) | 0 |
| Yield accrual dust | Routed to protocol fee | Protocol | `VIRTUAL_SHARES / effectiveShares * yield` |
| Withdrawal dust prevention | All shares burned | User (gets full balance) | `dustThreshold = minimumDeposit / 10` |
| `truncateTo6DecimalPrecision` (connector) | Floor to 6 decimals | Yield source (retains sub-6dp dust) | 0.00000099 |

All rounding favors the protocol or is explicitly handled to prevent dust accumulation. Users never receive more than they are owed.

## PR #55: PercentageSplit Rounding Overflow

**Bug**: When `prizeSplits` contains many small percentages, `totalPrizeAmount * split` rounded up for each winner could cause `calculatedSum` to exceed `totalPrizeAmount`. The final `totalPrizeAmount - calculatedSum` subtraction would then underflow and panic, bricking `completeDraw()`.

**Fix**: Added a guard: if `calculatedSum >= totalPrizeAmount`, the last winner receives `0.0` instead of attempting the subtraction. This prevents the panic while preserving the "last winner gets remainder" pattern for normal cases.

## Accuracy vs ACCOUNTING.md

The ACCOUNTING.md documentation uses a simplified model for exposition. Two differences from current code:

| Item | ACCOUNTING.md | Current code |
|------|---------------|--------------|
| `convertToShares` formula | `(assets * effectiveShares) / effectiveAssets` | `assets / sharePrice` where `sharePrice = effectiveAssets / effectiveShares` |
| Virtual offset values | Described as `+1.0` in formulas | Actual value is `0.0001` (set in contract init) |

Both formulas are mathematically equivalent. The code's two-step approach (compute price, then divide) may introduce one additional truncation step vs the single-division form in the docs, but the difference is at most 1 unit (0.00000001).

The `MINIMUM_DISTRIBUTION_THRESHOLD` (0.000001) ensures yield amounts too small to split meaningfully across percentage buckets are deferred to the next sync cycle rather than lost to rounding.
