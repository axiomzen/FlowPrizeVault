# Randomness

## Randomness Source

Flow's `RandomConsumer` implements a commit-reveal pattern tied to the block hash:

1. `requestRandomness()` records the current block height (commit).
2. At least 1 block must pass.
3. `fulfillRandomRequest()` derives a `UInt64` from the block hash at the committed height (reveal).

**Guarantees**: The random value is unpredictable at commit time. Validators cannot selectively withhold blocks on Flow (no leader-selection-based manipulation). The value is deterministic once the committed block is finalized.

**Limitation**: The output is a single `UInt64` (64 bits of entropy). Multi-winner draws require expanding this into a PRNG sequence.

## PRNG: Xorshift128plus

The contract uses Flow's `Xorshift128plus.PRG` for deterministic multi-winner selection from the single beacon seed.

**Seeding** (post-PR #53):
```
s0 = seed.toBigEndianBytes()                    // 8 bytes from beacon
s1 = (seed ^ 0x9e3779b97f4a7c15).toBigEndianBytes()  // 8 bytes, XOR with golden ratio constant
randomBytes = s0 ++ s1                           // 16 bytes total
PRG = Xorshift128plus.PRG(sourceOfRandomness: randomBytes, salt: [])
```

| Property | Value |
|----------|-------|
| State space | 2^128 (two distinct 64-bit halves) |
| Period | 2^128 - 1 |
| Output | 64-bit unsigned integers via `nextUInt64()` |

## PR #53: Seed Expansion Bug

**Bug**: The original code duplicated the 8-byte seed to fill the 16-byte state (`s0 == s1`), collapsing the PRNG state space from 2^128 to 2^64. Worse, Xorshift128plus has known weaknesses when `s0 == s1` -- the output sequence degenerates and exhibits detectable patterns.

**Fix**: XOR the seed with the Fibonacci hashing constant (`0x9e3779b97f4a7c15`) to produce a distinct second half, ensuring `s0 != s1` and utilizing the full 2^128 state space.

## Winner Selection Algorithm

1. During `processDrawBatch()`, each user's finalized TWAB (normalized weight) + bonus weight is added to a cumulative weight array.
2. `BatchSelectionData` stores parallel arrays: `receiverIDs[]` and `cumulativeWeights[]`.
3. For each winner slot:
   a. PRNG generates a `UInt64`.
   b. Scale to `[0, totalWeight)`: `randomValue = (rng % 1_000_000_000) / 1_000_000_000.0 * totalWeight`.
   c. Binary search `cumulativeWeights` for first index where `cumulativeWeights[i] > randomValue`.
   d. If index already selected, reject and retry (rejection sampling).
4. Safety: max retries = `receiverCount * 3`. If exhausted, fill remaining slots with unselected participants in order.

| Step | Complexity |
|------|-----------|
| Weight capture | O(n) across batches |
| Single winner lookup | O(log n) binary search |
| k winners total | O(k * log n) average (with rejection sampling) |

**Precision**: Random scaling uses 9 decimal digits (`1_000_000_000`). This gives ~1 ppb granularity over the weight space. For a pool with 100,000 users of equal weight, the maximum selection bias per user is < 0.001%.

## Manipulation Resistance

| Attack | Mitigation |
|--------|-----------|
| Last-minute deposit to inflate odds | TWAB weights by time: a deposit at 99% of the round gets ~1% of full-round weight |
| Withdraw after seeing randomness committed | Weights are frozen at `startDraw()` (snapshot before randomness reveal). Withdrawals during processing do not change draw weights |
| Validator collusion on randomness | Flow's consensus makes block withholding uneconomic; `RandomConsumer` uses committed block hash |
| Deposit during batch processing | New deposits after `startDraw()` are excluded via `snapshotReceiverCount`. The active round's `actualEndTime` caps TWAB accumulation |
| Sybil attack (many small accounts) | TWAB is proportional to `shares * time`. Splitting across accounts yields the same total weight as a single account |

## Bonus Weights

Admins can assign bonus weights to specific receivers for promotional purposes.

| Property | Detail |
|----------|--------|
| Unit | Equivalent "average shares" (same unit as normalized TWAB) |
| Max per user | `MAX_BONUS_WEIGHT_PER_USER` (contract constant) |
| Time scaling | None needed -- TWAB is already normalized to average shares |
| Effect | `totalWeight = twabStake + bonusWeight` per user |
| Audit trail | On-chain events (`BonusLotteryWeightSet`, `BonusLotteryWeightAdded`, `BonusLotteryWeightRemoved`) with reason, timestamp, and admin UUID |

A bonus of `5.0` is equivalent to holding 5 additional tokens for the entire round duration, regardless of actual round length.
