# PrizeLinkedAccounts Computation Benchmark Findings

This document summarizes the findings from computation profiling of the PrizeLinkedAccounts draw operations on the Flow blockchain.

## Executive Summary

| Operation | Limit | Recommended Safe Value |
|-----------|-------|------------------------|
| `processDrawBatch` (active users) | ~3,075 users/batch | 2,500 users/batch |
| `processDrawBatch` (lazy users) | ~2,300 users/batch | 1,900 users/batch |
| `completeDraw` (≤10% selection) | ~4.7 CU/winner | Consistent ✅ |
| `completeDraw` (>50% selection) | Variable | Keep selection ratio low |

**Key Findings**:
- Lazy users (no activity in current round) cost **~34% more computation** than active users
- Binary search fix (2025-12-23) reduced `completeDraw` variance from **250x to ~25x** for high selection ratios
- With realistic selection ratios (≤10%), `completeDraw` is now **completely consistent**

---

## 1. Active vs Lazy User Cost Analysis

### Finding: Lazy Users Cost 34% More Computation

Users who deposited in a **previous round** but have no activity in the **current round** ("lazy users") require significantly more computation than users who deposited during the current round ("active users").

### Test Results

| Users | Active (Round 0) | Per User | Lazy (Round 1) | Per User | Difference |
|------:|----------------:|---------:|---------------:|---------:|-----------:|
| 50    | 175 CU          | 3.50     | 230 CU         | 4.60     | +31.4%     |
| 100   | 334 CU          | 3.34     | 443 CU         | 4.43     | +32.6%     |
| 200   | 652 CU          | 3.26     | 871 CU         | 4.36     | +33.6%     |
| 500   | 1,607 CU        | 3.21     | 2,154 CU       | 4.31     | +34.0%     |

### Why Lazy Users Cost More

**Active users** (deposited this round):
- Have TWAB dictionary entries populated during their deposit
- `finalizeTWAB` reads pre-computed values directly from dictionaries
- Cost: ~3.25 CU/user

**Lazy users** (deposited in previous round, no activity this round):
- Have NO TWAB dictionary entries in the current round
- `finalizeTWAB` uses nil coalescing (`??`) to fall back to defaults
- Must calculate TWAB from scratch using `currentShares` parameter
- Cost: ~4.35 CU/user

### Code Path Analysis

In `finalizeTWAB`:
```cadence
let accumulated = self.userAccumulatedTWAB[receiverID] ?? 0.0
let lastUpdate = self.userLastUpdateTime[receiverID] ?? self.startTime
let shares = self.userSharesAtLastUpdate[receiverID] ?? currentShares
```

For **active users**: All three dictionary lookups succeed, returning stored values.
For **lazy users**: All three lookups return `nil`, triggering fallback calculations.

### Batch Size Implications

Given the 34% higher cost for lazy users, batch size recommendations differ:

| User Type | CU/User | Max Users (9,999 CU limit) | Safe Batch Size |
|-----------|---------|---------------------------|-----------------|
| Active    | ~3.25   | ~3,075                    | 2,500           |
| Lazy      | ~4.35   | ~2,300                    | 1,900           |
| Mixed     | ~3.80   | ~2,630                    | 2,100           |

**Recommendation**: Use a conservative batch size of **2,000 users** to safely handle any mix of active and lazy users.

### Run the Benchmark

```bash
python3 benchmark/benchmark_lazy_users.py --users 100
python3 benchmark/benchmark_lazy_users.py --users 500 --debug  # With debug output
```

---

## 2. processDrawBatch - User Processing Limits

### Finding: Linear Scaling with ~3,075 User Maximum

The `processDrawBatch` function scales **linearly** with the number of users processed.

**Formula**: `computation ≈ 10 + (3.25 × users)`

### Test Results

| Users | Computation | Per User | Status |
|------:|------------:|---------:|:------:|
| 10    | 43          | 4.30     | ✅ |
| 50    | 178         | 3.56     | ✅ |
| 100   | 340         | 3.40     | ✅ |
| 500   | 1,609       | 3.22     | ✅ |
| 1,000 | 3,250       | 3.25     | ✅ |
| 2,000 | 6,460       | 3.23     | ✅ |
| 3,000 | 9,768       | 3.26     | ✅ |
| 3,050 | 9,905       | 3.25     | ✅ |
| 3,075 | 9,948       | 3.24     | ✅ |
| 3,080 | exceeded    | -        | ❌ |

### Recommended Batch Sizes

Given Flow's ~9,999 computation limit per transaction:

- **Aggressive**: 3,000 users/batch (leaves ~230 units headroom)
- **Safe**: 2,500 users/batch (leaves ~1,875 units headroom)
- **Conservative**: 2,000 users/batch (leaves ~3,500 units headroom)

### What processDrawBatch Does

For each user in the batch:
1. Finalizes their TWAB (Time-Weighted Average Balance)
2. Calculates their lottery weight based on time-held shares
3. Adds to cumulative weight array for winner selection

### Internal Computation Profile (1000 users)

Using `--computation-profiling`, we analyzed the internal call structure:

```
PrizeLinkedAccounts.Pool.processDrawBatch (211,001,192 = 100%)
├── finalizeTWAB              94,579,300 (44.82%)  ◀ LARGEST HOTSPOT
├── Loop overhead             73,115,675 (34.67%)
├── getBonusWeight            19,444,000 (9.22%)
├── getUserShares             19,444,000 (9.22%)
└── addEntry                   4,316,300 (2.05%)
```

**Key insight**: The function performs **5 dictionary lookups per user**:
- `finalizeTWAB`: 3 lookups (`userAccumulatedTWAB`, `userLastUpdateTime`, `userSharesAtLastUpdate`)
- `getUserShares`: 1 lookup
- `getBonusWeight`: 1 lookup

### Optimization Opportunities

#### Optimization 1: Combine TWAB State Into Single Struct (High Impact)

**Current implementation** (PrizeLinkedAccounts.cdc Round resource):
```cadence
access(self) let userAccumulatedTWAB: {UInt64: UFix64}
access(self) let userLastUpdateTime: {UInt64: UFix64}
access(self) let userSharesAtLastUpdate: {UInt64: UFix64}
```

**Proposed**: Single struct dictionary
```cadence
access(all) struct TWABState {
    access(all) let accumulated: UFix64
    access(all) let lastUpdate: UFix64
    access(all) let sharesAtLastUpdate: UFix64
}

access(self) let userTWABState: {UInt64: TWABState}
```

**Expected savings**: ~15-25% reduction in `finalizeTWAB` (1 lookup vs 3)

---

#### Optimization 2: Early Skip Zero-Share Users (Medium Impact)

**Current**: Processes all users, including those with 0 shares
```cadence
while i < endIndex {
    let shares = self.shareTracker.getUserShares(receiverID)
    let twabStake = pendingRound.finalizeTWAB(...)  // Called even if shares=0
    selectionData.addEntry(...)  // addEntry checks weight > 0 later
}
```

**Proposed**: Skip early to avoid expensive `finalizeTWAB`
```cadence
while i < endIndex {
    let receiverID = self.registeredReceiverList[i]
    let shares = self.shareTracker.getUserShares(receiverID)

    if shares == 0.0 {
        i = i + 1
        continue  // Skip expensive finalizeTWAB for zero-share users
    }
    // ... rest of processing
}
```

**Expected savings**: ~5-10% for pools with withdrawn users

---

#### Optimization 3: Cache Round End Time (Low Impact)

**Current**: Computed every `finalizeTWAB` call
```cadence
// In finalizeTWAB (called 1000x for 1000 users)
let configuredEndTime = self.startTime + self.duration  // Redundant
```

**Proposed**: Pre-compute at round creation
```cadence
access(self) let configuredEndTime: UFix64  // Set once in init()
```

**Expected savings**: ~1-2%

---

#### Optimization 4: Batch User Data Retrieval (Medium Impact)

Instead of 5 separate dictionary lookups per user across different resources, create a combined lookup:

```cadence
access(all) struct DrawUserData {
    access(all) let shares: UFix64
    access(all) let bonusWeight: UFix64
    access(all) let twabState: TWABState
}

// New helper in Pool
access(contract) view fun getUserDrawData(receiverID: UInt64, round: &Round): DrawUserData {
    return DrawUserData(
        shares: self.shareTracker.getUserShares(receiverID),
        bonusWeight: self.getBonusWeight(receiverID),
        twabState: round.getTWABState(receiverID)
    )
}
```

**Expected savings**: ~5-10% from reduced function call overhead

---

### Optimization Summary Table

| Priority | Optimization | Expected Savings | Effort | Risk |
|----------|--------------|------------------|--------|------|
| **High** | Combine TWAB dictionaries into struct | 15-25% | Medium | Low |
| **Medium** | Early skip zero-share users | 5-10% | Low | Very Low |
| **Medium** | Batch user data retrieval | 5-10% | Medium | Low |
| **Low** | Cache round end time | 1-2% | Low | Very Low |

**Total potential savings**: 25-45% of `processDrawBatch` computation

**Biggest win**: Combining the 3 TWAB dictionaries into a single struct would reduce `finalizeTWAB` from 44.82% to approximately 20-25% of the function's cost.

---

## 3. completeDraw - Winner Selection (FIXED)

### Finding: Consistent Computation with Binary Search

The `completeDraw` function now uses **binary search with rejection sampling** for winner selection (implemented 2025-12-23). This provides consistent O(k × log n) complexity.

### Test Results (125 winners, 175 users, 5 runs)

| Run | Computation | Per Winner | Variance |
|-----|------------:|-----------:|----------|
| 1   | 107         | 0.86       | LOW      |
| 2   | 2,404       | 19.23      | MEDIUM   |
| 3   | 2,472       | 19.78      | MEDIUM   |
| 4   | 107         | 0.86       | LOW      |
| 5   | 2,743       | 21.94      | MEDIUM   |

**Variance ratio**: ~25x (down from 250x with linear search)

### Why Variance Still Exists: Rejection Sampling Collisions

The remaining variance is **not** from the binary search (which is O(log n) and consistent). It comes from the **rejection sampling** algorithm used for selecting winners without replacement.

#### How the Algorithm Works

```
For each winner to select:
1. Generate random number in [0, totalWeight)
2. Binary search to find winner index        ← O(log n), consistent
3. Check if this index was already selected
4. If COLLISION (already selected) → RETRY from step 1
5. If not selected → Accept winner, continue to next
```

#### Why Collisions Increase Over Time

When selecting 125 winners from 175 users:

| Winner # | Already Selected | Collision Probability | Expected Retries |
|---------:|-----------------:|----------------------:|-----------------:|
| 1        | 0/175            | 0%                    | 1.0              |
| 25       | 24/175           | 14%                   | 1.2              |
| 50       | 49/175           | 28%                   | 1.4              |
| 75       | 74/175           | 42%                   | 1.7              |
| 100      | 99/175           | 57%                   | 2.3              |
| 120      | 119/175          | 68%                   | 3.1              |
| 125      | 124/175          | **71%**               | **3.4**          |

The **last few winners** can require many retries because most indices are already taken.

#### Worked Example

**LOW computation run** (107 CU): Random numbers happened to select mostly unselected indices early, resulting in few collisions.

**MEDIUM computation run** (2,743 CU): Random numbers frequently hit already-selected indices, especially toward the end, requiring many retries.

#### Mathematical Explanation

For a selection ratio of `s = winners/users`:
- Expected retries for winner `i` ≈ `1 / (1 - i/users)`
- Total expected retries ≈ `users × ln(users / (users - winners))`

For 125/175 (71% selection):
- Expected total retries ≈ 175 × ln(175/50) ≈ 175 × 1.25 ≈ **219 retries**
- But actual retries vary based on random number distribution

For 50/500 (10% selection):
- Expected total retries ≈ 500 × ln(500/450) ≈ 500 × 0.105 ≈ **53 retries**
- Variance is minimal because collision probability stays low throughout

### With Lower Selection Ratios: Perfect Consistency

| Winners | Users | Selection Ratio | Variance | CU/Winner |
|--------:|------:|----------------:|:--------:|----------:|
| 50      | 100   | 50%             | 30x      | 1.5-46    |
| 125     | 175   | 71%             | 25x      | 0.9-22    |
| 50      | 500   | 10%             | **1.0x** | 4.68      |

**Key insight**: With realistic winner ratios (≤10%), computation is completely deterministic.

### Previous Problem (Linear Search)

The old implementation had up to **250x variance** (37-9,461 CU for same input) due to linear search:

| Run | Old (Linear) | New (Binary) | Improvement |
|-----|-------------:|-------------:|:-----------:|
| Best | 37 CU       | 107 CU       | Similar     |
| Worst | 9,461 CU   | 2,743 CU     | **3.4x**    |

### Current Implementation

**Location**: `PrizeLinkedAccounts.cdc` lines 2778-2795

```cadence
// Binary search: O(log n) per winner lookup
access(all) view fun findWinnerIndex(randomValue: UFix64): Int {
    var low = 0
    var high = self.receiverIDs.length - 1

    while low < high {
        let mid = (low + high) / 2
        if self.cumulativeWeights[mid] <= randomValue {
            low = mid + 1
        } else {
            high = mid
        }
    }
    return low
}
```

The algorithm uses rejection sampling to handle duplicate selection:
1. Generate random value in [0, totalWeight)
2. Binary search to find winner index - O(log n)
3. If already selected, retry with new random value
4. Repeat until all winners selected

### Complexity Analysis

| Algorithm | Best Case | Worst Case | Notes |
|-----------|-----------|------------|-------|
| Old (Linear) | O(k) | O(k × n) | Depended on random values |
| New (Binary) | O(k × log n) | O(k × log n × r) | r = retry factor for collisions |

Where:
- k = number of winners
- n = number of users
- r = average retries (≈1 for low selection ratios, higher for >50% selection)

---

## 4. Other Draw Phases (Constant Cost)

| Phase | Computation | Notes |
|-------|-------------|-------|
| `startPoolDraw` | 34-61 | Creates new round, moves state |
| `requestDrawRandomness` | 19-21 | Requests on-chain randomness |

These phases have minimal, constant computation regardless of user count.

---

## 5. Full Draw Cycle Example

For a pool with 500 users and 50 winners (10% selection):

| Phase | Computation | Notes |
|-------|-------------|-------|
| startPoolDraw | ~305 | Constant |
| processDrawBatch | ~1,606 | Linear with users |
| requestDrawRandomness | ~20-45 | Constant |
| completeDraw | ~234 | **Consistent!** (binary search) |
| **Total** | ~2,165-2,190 | Predictable, well under 9,999 CU |

For a pool with 175 users and 125 winners (71% selection - edge case):

| Phase | Computation | Notes |
|-------|-------------|-------|
| startPoolDraw | ~125 | Constant |
| processDrawBatch | ~573 | Linear with users |
| requestDrawRandomness | ~20-45 | Constant |
| completeDraw | 107-2,743 | Variable due to rejection sampling collisions |
| **Total** | ~825-3,500 | Still safe, but variable |

---

## 6. Recommendations

### Implemented ✅
1. ~~**Implement binary search** in `selectWinners` function~~ - Done 2025-12-23

### Short-term
1. **Use conservative batch sizes** for `processDrawBatch` (2,500 users/batch)
2. **Monitor completeDraw transactions** for computation spikes with high selection ratios
3. **Limit winner-to-user ratio** - Keep selection ratio ≤30% for consistent computation

### Medium-term
1. **Add computation estimation** before executing completeDraw
2. **Consider batched winner selection** for large winner counts with high selection ratios
3. **Pre-populate TWAB entries** at round start to eliminate lazy user overhead

### Long-term
1. **Evaluate alternative algorithms** (e.g., Fisher-Yates with weight adjustment) for >50% selection ratios
2. **Add circuit breakers** for computation limits
3. **Consider off-chain winner selection** with on-chain verification for extreme cases

---

## 7. Testing Methodology

### Tools Used
- Flow Emulator with `--computation-profiling` and `--computation-reporting` flags
- `go tool pprof` for flame graph and call stack analysis
- Custom Python benchmark scripts

### Files
- `benchmark/benchmark_draw_computation.py` - processDrawBatch benchmarks
- `benchmark/benchmark_complete_draw.py` - completeDraw benchmarks
- `benchmark/transactions/setup_benchmark_users.cdc` - User creation
- `benchmark/transactions/create_multi_winner_pool.cdc` - Multi-winner pool setup

### Profiling Commands
```bash
# Start emulator with profiling
flow emulator --computation-profiling --computation-reporting

# Download profile after transactions
curl -o profile.pprof http://localhost:8080/emulator/computationProfile

# Analyze with pprof
go tool pprof -top profile.pprof
go tool pprof -http=:8081 profile.pprof  # Interactive web UI
```

---

## Appendix: Key Code Locations

### Draw Phase Functions

| Function | File | Lines | Purpose |
|----------|------|-------|---------|
| `processDrawBatch` | PrizeLinkedAccounts.cdc | 4084-4164 | Batch TWAB finalization |
| `completeDraw` | PrizeLinkedAccounts.cdc | ~4280 | Winner selection & prize distribution |
| `selectWinners` | PrizeLinkedAccounts.cdc | 2761-2821 | Weighted random selection |
| `getWeight` | PrizeLinkedAccounts.cdc | 2738-2744 | Individual weight lookup |
| `distributePrizes` | PrizeLinkedAccounts.cdc | 2196+ | Prize distribution to winners |

### processDrawBatch Internal Functions (Optimization Targets)

| Function | File | Lines | % of Computation | Purpose |
|----------|------|-------|------------------|---------|
| `finalizeTWAB` | PrizeLinkedAccounts.cdc | 1475-1501 | 44.82% | Calculate final TWAB for user |
| `accumulatePendingTWAB` | PrizeLinkedAccounts.cdc | 1388-1419 | (called during deposits) | Accumulate TWAB state |
| `getUserShares` | PrizeLinkedAccounts.cdc | 1814-1816 | 9.22% | Dictionary lookup for shares |
| `getBonusWeight` | PrizeLinkedAccounts.cdc | 4575-4577 | 9.22% | Dictionary lookup for bonus |
| `addEntry` | PrizeLinkedAccounts.cdc | 2674-2680 | 2.05% | Add to selection data arrays |

### TWAB State Dictionaries (Optimization Target)

| Dictionary | Location | Purpose |
|------------|----------|---------|
| `userAccumulatedTWAB` | Round resource | Accumulated normalized weight |
| `userLastUpdateTime` | Round resource | Last TWAB update timestamp |
| `userSharesAtLastUpdate` | Round resource | Shares at last update |
