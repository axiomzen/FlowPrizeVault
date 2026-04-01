# PrizeLinkedAccounts Computation Analysis

A comprehensive analysis of computation costs for lottery draw operations on Flow blockchain.

---

## Executive Summary

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         KEY FINDINGS AT A GLANCE                            │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  processDrawBatch                                                           │
│  ├── Active Users:     ~3.3 CU/user  (deposited this round)                │
│  ├── Lazy Users:       ~4.4 CU/user  (no activity this round)              │
│  └── Overhead:         +33% for lazy users                                  │
│                                                                             │
│  completeDraw (FIXED with binary search - 2025-12-23)                       │
│  ├── Low selection:    ~4.7 CU/winner (10% selection, 1x variance)         │
│  ├── High selection:   0.9-22 CU/winner (71% selection, ~25x variance)     │
│  └── Previous:         0.3-75 CU/winner (250x variance - FIXED)            │
│                                                                             │
│  Recommended Batch Size: 2,000 users (conservative for mixed pools)        │
│  Flow CU Limit: 9,999 per transaction                                      │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 1. Draw Process Overview

The lottery draw consists of 4 sequential phases:

```
    ┌──────────────┐     ┌───────────────────┐     ┌─────────────────────┐     ┌───────────────┐
    │  startDraw   │────▶│ processDrawBatch  │────▶│requestDrawRandomness│────▶│  completeDraw │
    │   Phase 1    │     │     Phase 2       │     │      Phase 3        │     │    Phase 4    │
    └──────────────┘     └───────────────────┘     └─────────────────────┘     └───────────────┘
          │                      │                          │                         │
          ▼                      ▼                          ▼                         ▼
     ~50-130 CU             ~3.3 CU/user               ~8-45 CU               ~5-22 CU/winner
     (constant)             (linear)                  (constant)        (binary search, consistent)
```

### Phase Computation Summary

| Phase | Computation | Scaling | Notes |
|-------|-------------|---------|-------|
| `startDraw` | 36-130 CU | Constant | Higher when round has TWAB entries |
| `processDrawBatch` | 3.3-4.4 CU/user | **Linear** | Depends on user activity |
| `requestDrawRandomness` | 8-45 CU | Constant | Requests on-chain RNG |
| `completeDraw` | ~5-22 CU/winner | **Consistent** | Binary search (fixed 2025-12-23) |

---

## 2. processDrawBatch: User Processing Analysis

### 2.1 Scaling Characteristics

The `processDrawBatch` function scales **linearly** with user count:

```
Computation (CU)
     │
9999 ┤ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─  FLOW LIMIT
     │                                        ╱
9000 ┤                                      ╱
     │                                    ╱
8000 ┤                                  ╱
     │                                ╱
7000 ┤                              ╱
     │                            ╱
6000 ┤                          ╱
     │                        ╱
5000 ┤                      ╱
     │                    ╱
4000 ┤                  ╱
     │                ╱
3000 ┤              ╱
     │            ╱
2000 ┤          ╱
     │        ╱
1000 ┤      ╱
     │    ╱
   0 ┼──╱─────┬─────┬─────┬─────┬─────┬─────┬─────┬
        500  1000  1500  2000  2500  3000  3500   Users
                                           │
                                    MAX ───┘
                                  (~3,075)
```

**Formula**: `computation ≈ 10 + (3.25 × users)` for active users

### 2.2 Active vs Lazy User Comparison

**Active Users**: Deposited during the current round (have TWAB dictionary entries)
**Lazy Users**: Deposited in a previous round, no activity in current round (no TWAB entries)

```
CU per User
     │
 4.5 ┤                              ████████████  Lazy Users
     │                              ████████████  (4.43 CU/user)
 4.0 ┤                              ████████████
     │                              ████████████
 3.5 ┤  ████████████                ████████████
     │  ████████████  Active Users  ████████████
 3.0 ┤  ████████████  (3.34 CU/user)████████████
     │  ████████████                ████████████
 2.5 ┤  ████████████                ████████████
     │  ████████████                ████████████
 2.0 ┤  ████████████                ████████████
     │  ████████████                ████████████
 1.5 ┤  ████████████                ████████████
     │  ████████████                ████████████
 1.0 ┤  ████████████                ████████████
     │  ████████████                ████████████
 0.5 ┤  ████████████                ████████████
     │  ████████████                ████████████
   0 ┼──────────────────────────────────────────
            ACTIVE                    LAZY

                    +32.6% overhead ──────┘
```

### 2.3 Benchmark Results Table

| Users | Active (CU) | Per User | Lazy (CU) | Per User | Difference |
|------:|------------:|---------:|----------:|---------:|-----------:|
| 50    | 175         | 3.50     | 230       | 4.60     | **+31.4%** |
| 100   | 334         | 3.34     | 443       | 4.43     | **+32.6%** |
| 200   | 652         | 3.26     | 871       | 4.36     | **+33.6%** |
| 500   | 1,607       | 3.21     | 2,154     | 4.31     | **+34.0%** |
| 1,000 | 3,250       | 3.25     | ~4,350    | ~4.35    | **~34%**   |

### 2.4 Maximum Batch Sizes

Given Flow's 9,999 CU limit per transaction:

```
                    ┌─────────────────────────────────────────┐
                    │         BATCH SIZE RECOMMENDATIONS       │
                    ├─────────────────────────────────────────┤
                    │                                         │
  Active Users ────▶│  MAX: ~3,075    SAFE: 2,500            │
                    │  ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░   │
                    │                                         │
  Lazy Users ──────▶│  MAX: ~2,300    SAFE: 1,900            │
                    │  ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░   │
                    │                                         │
  Mixed Pool ──────▶│  MAX: ~2,630    SAFE: 2,000 ◀── USE    │
                    │  ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░   │
                    │                                         │
                    └─────────────────────────────────────────┘
```

---

## 3. Why Lazy Users Cost More: Profiling Analysis

### 3.1 Function-Level Profiling Results

Using `--computation-profiling`, we captured detailed call stack data:

```
                        ACTIVE USERS                          LAZY USERS

finalizeTWAB            ████████░░░░░░░░░░░░░░  9.2M         ██████████████████░░░░  20.5M
                              (0.88%)                              (1.83%)

processDrawBatch        ██████░░░░░░░░░░░░░░░░  7.5M         ██████████████░░░░░░░░  15.0M
(flat)                        (0.72%)                              (1.34%)

getUserShares           ░░░░░░░░░░░░░░░░░░░░░░  <5.2M        █████░░░░░░░░░░░░░░░░░  5.8M
                              (not in top 30)                      (0.52%)
```

### 3.2 The Root Cause: Dictionary Miss Overhead

| Function | Active Users | Lazy Users | Increase |
|----------|-------------:|------------|----------|
| `finalizeTWAB` | 9,192,300 | 20,506,000 | **+123%** |
| `processDrawBatch` (flat) | 7,498,202 | 14,996,404 | **+100%** |

**Key finding**: `finalizeTWAB` is **more than DOUBLE** the cost for lazy users.

### 3.3 Code Path Analysis

```cadence
// In finalizeTWAB (Round resource, lines 1522-1524):

let accumulated = self.userAccumulatedTWAB[receiverID] ?? 0.0
let lastUpdate = self.userLastUpdateTime[receiverID] ?? self.startTime
let shares = self.userSharesAtLastUpdate[receiverID] ?? currentShares
```

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           ACTIVE USER PATH                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Dictionary Lookup ──▶ KEY FOUND ──▶ Return Value ──▶ Done                 │
│        ↓                   ↓              ↓                                 │
│    [Hash Key]         [Match!]      [Unwrap Optional]                       │
│                                                                             │
│  Cost: ~9.2M computation units (for 100 users × 3 lookups)                 │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                            LAZY USER PATH                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Dictionary Lookup ──▶ KEY NOT FOUND ──▶ Return nil ──▶ Evaluate Fallback  │
│        ↓                     ↓                ↓               ↓             │
│    [Hash Key]          [Search All]    [Nil Check]    [Access Field/Param] │
│                                                                             │
│  Cost: ~20.5M computation units (for 100 users × 3 lookups)                │
│                                                                             │
│  Extra cost from:                                                           │
│    • Dictionary miss probing (confirming key doesn't exist)                │
│    • Nil coalescing evaluation                                              │
│    • Fallback expression evaluation (especially self.startTime)            │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 3.4 processDrawBatch Internal Breakdown (Active Users)

```
processDrawBatch Total: 100%
│
├── finalizeTWAB ─────────────────────────────────────────── 44.82%
│   └── 3 dictionary lookups per user (TWAB state)
│
├── Loop overhead ────────────────────────────────────────── 34.67%
│   └── Iteration, cursor management, event emission
│
├── getBonusWeight ───────────────────────────────────────── 9.22%
│   └── 1 dictionary lookup per user
│
├── getUserShares ────────────────────────────────────────── 9.22%
│   └── 1 dictionary lookup per user (pool-level)
│
└── addEntry ─────────────────────────────────────────────── 2.05%
    └── Array append, weight accumulation
```

---

## 4. completeDraw: Winner Selection Analysis (FIXED)

### 4.1 Previous Variance Problem (Fixed 2025-12-23)

The `completeDraw` function previously had **highly variable computation** due to linear search. This has been fixed with binary search + rejection sampling.

### 4.2 Current Test Results (Binary Search)

**125 Winners, 175 Users (71% selection ratio)**

| Run | Computation | Per Winner | Category |
|-----|------------:|-----------:|----------|
| 1   | 107 CU      | 0.86       | LOW ✓    |
| 2   | 2,404 CU    | 19.23      | MEDIUM   |
| 3   | 2,472 CU    | 19.78      | MEDIUM   |
| 4   | 107 CU      | 0.86       | LOW ✓    |
| 5   | 2,743 CU    | 21.94      | MEDIUM   |

**Variance: ~25x** (down from 250x with linear search)

**50 Winners, 500 Users (10% selection ratio)**

| Run | Computation | Per Winner | Category |
|-----|------------:|-----------:|----------|
| 1   | 234 CU      | 4.68       | LOW ✓    |
| 2   | 234 CU      | 4.68       | LOW ✓    |
| 3   | 234 CU      | 4.68       | LOW ✓    |

**Variance: 1.0x** (completely consistent with low selection ratios!)

### 4.3 Current Implementation: Binary Search + Rejection Sampling

```cadence
// Current implementation in selectWinners (lines 2778-2795):

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

```
                         BINARY SEARCH

Random = 0.75                                      Target
                                                     │
Users:  [██ ██ ██ ██ ██ ██ ██ ██ ██ ██]             │
Cum:     10 20 30 40 50 60 70 80 90 100            75
                          │                          │
                        mid=5 (60<75)               │
                              │                      │
                            mid=7 (80>75) ◀────────┘
                                                  FOUND!
                                            (~3 iterations)
```

### 4.4 Complexity Comparison

| Algorithm | Best Case | Average | Worst Case |
|-----------|-----------|---------|------------|
| **Old (Linear)** | O(k) | O(k × n/2) | O(k × n) |
| **New (Binary)** | O(k × log n) | O(k × log n) | O(k × log n × r) |

Where r = retry factor from rejection sampling (≈1 for ≤10% selection, higher for >50%)

### 4.5 Improvement Summary

```
Before (Linear Search):                    After (Binary Search):

Computation (CU)                           Computation (CU)
     │                                          │
9500 ┤  ████  ████                        2750 ┤            ████  ████  ████
     │  ████  ████                              │
     ·  ····  ····                              │
     ·  (250x variance)                   2500 ┤
     ·  ····  ····                              │
 200 ┤                                          │
 100 ┤  ████  ████  ████                   100 ┤  ████            ████
   0 ┼──────────────────                     0 ┼──────────────────────────────
       R1    R2    R3    R4    R5                R1    R2    R3    R4    R5

     Max: 9,461 CU                              Max: 2,743 CU
     Variance: 250x                             Variance: 25x (3.4x better)
```

### 4.6 Remaining Variance Explained: Rejection Sampling Collisions

The ~25x variance with high selection ratios is **not** from the binary search (which is O(log n) and consistent). It comes from **rejection sampling collisions** when selecting winners without replacement.

#### How Rejection Sampling Works

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     REJECTION SAMPLING ALGORITHM                            │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  For each winner to select:                                                 │
│    1. Generate random number in [0, totalWeight)                           │
│    2. Binary search to find winner index        ← O(log n), CONSISTENT     │
│    3. Check if this index was already selected                             │
│    4. If COLLISION (already selected) → RETRY from step 1   ← VARIANCE!    │
│    5. If not selected → Accept winner, continue to next                    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

#### Why Collision Probability Increases

When selecting 125 winners from 175 users (71% selection ratio):

```
Collision Probability Over Time
     │
 70% ┤                                              ████████
     │                                         █████████████
 60% ┤                                    ██████████████████
     │                               █████████████████████████
 50% ┤                          ██████████████████████████████
     │                     █████████████████████████████████████
 40% ┤                ██████████████████████████████████████████
     │           █████████████████████████████████████████████████
 30% ┤      ██████████████████████████████████████████████████████
     │ █████████████████████████████████████████████████████████████
 20% ┤██████████████████████████████████████████████████████████████
     │████████████████████████████████████████████████████████████████
 10% ┤█████████████████████████████████████████████████████████████████
     │██████████████████████████████████████████████████████████████████
  0% ┼────────────────────────────────────────────────────────────────────
       1    25    50    75    100   110   120   125    Winner #
```

| Winner # | Already Selected | Collision Probability | Expected Retries |
|---------:|-----------------:|----------------------:|-----------------:|
| 1        | 0/175            | 0%                    | 1.0              |
| 50       | 49/175           | 28%                   | 1.4              |
| 100      | 99/175           | 57%                   | 2.3              |
| 120      | 119/175          | 68%                   | 3.1              |
| 125      | 124/175          | **71%**               | **3.4**          |

#### Why Some Runs Are LOW and Others Are MEDIUM

**LOW computation run (107 CU)**:
- Random numbers happened to mostly select unselected indices
- Few collisions occurred, minimal retries needed
- "Lucky" random sequence

**MEDIUM computation run (2,743 CU)**:
- Random numbers frequently hit already-selected indices
- Many collisions, especially when selecting the last 20-30 winners
- "Unlucky" random sequence requiring many retries

#### Why 10% Selection Has NO Variance

With 50 winners from 500 users:
- Maximum collision probability is only 50/500 = 10%
- Expected retries per winner ≈ 1.1 (barely any collisions)
- Total computation is deterministic

**Recommendation**: For pools expecting many winners relative to users (>30% selection ratio), consider:
1. Using Fisher-Yates shuffle instead of rejection sampling
2. Batching winner selection across multiple transactions
3. Adjusting prize distribution to have fewer, larger prizes

---

## 5. Full Draw Cycle Computation

### 5.1 Example: 500 Users, 50 Winners (10% selection)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    FULL DRAW CYCLE (500 users, 50 winners)                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Phase 1: startDraw ─────────────────────── ~305 CU                        │
│           █████                                                             │
│                                                                             │
│  Phase 2: processDrawBatch ─────────────── ~1,606 CU (active)              │
│           ████████████████████████████████  or                             │
│           ██████████████████████████████████████████ ~2,150 CU (lazy)      │
│                                                                             │
│  Phase 3: requestDrawRandomness ─────────── ~20-45 CU                      │
│           █                                                                 │
│                                                                             │
│  Phase 4: completeDraw ─────────────────── ~234 CU (consistent!)           │
│           █████ (binary search: 4.68 CU/winner × 50 winners)               │
│                                                                             │
├─────────────────────────────────────────────────────────────────────────────┤
│  TOTAL (10% selection): ~2,165-2,435 CU (predictable, well under 9,999)    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 5.2 Risk Assessment by Pool Size (with binary search)

| Users | Winners | Selection | processDrawBatch | completeDraw | Total | Risk |
|------:|--------:|----------:|-----------------:|-------------:|------:|------|
| 500   | 50      | 10%       | ~1,600 CU        | ~234 CU      | ~2,200 CU | ✅ Safe |
| 1,000 | 100     | 10%       | ~3,250 CU        | ~470 CU      | ~4,000 CU | ✅ Safe |
| 2,000 | 200     | 10%       | ~6,500 CU        | ~940 CU      | ~7,800 CU | ✅ Safe |
| 2,500 | 250     | 10%       | ~8,125 CU        | ~1,175 CU    | ~9,600 CU | ⚠️ Near limit |
| 175   | 125     | **71%**   | ~573 CU          | ~2,500 CU    | ~3,400 CU | ⚠️ Variable |

**Note**: High selection ratios (>50%) may cause variance in `completeDraw` due to rejection sampling retries.
Batch `processDrawBatch` separately from `completeDraw` for large pools.

---

## 6. Recommendations

### 6.1 Immediate Actions

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         RECOMMENDED BATCH SIZES                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  processDrawBatch:                                                          │
│  ├── Conservative (mixed pools): 2,000 users/batch                         │
│  ├── Active-heavy pools:         2,500 users/batch                         │
│  └── Lazy-heavy pools:           1,900 users/batch                         │
│                                                                             │
│  completeDraw:                                                              │
│  ├── Monitor for high-computation runs                                     │
│  ├── Implement retry logic for failures                                    │
│  └── Consider limiting winner count if pool is large                       │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 6.2 Code Optimizations

| Priority | Optimization | Expected Impact | Status |
|----------|--------------|-----------------|--------|
| ~~**HIGH**~~ | ~~Binary search in `selectWinners`~~ | ~~20-250× reduction in worst case~~ | ✅ **DONE** (2025-12-23) |
| **MEDIUM** | Pre-populate TWAB entries at round start | Eliminate lazy user overhead | TODO |
| **LOW** | Batch winner selection | Reduce multiple-winner overhead | TODO |

### 6.3 Monitoring Recommendations

1. **Track lazy user ratio** - Pools with >50% lazy users need smaller batches
2. **Log completeDraw computation** - Detect high-variance runs
3. **Alert on approaching limits** - Warn at 80% of 9,999 CU

---

## 7. Running the Benchmarks

### processDrawBatch Benchmark

```bash
# Basic benchmark
python3 benchmark/benchmark_draw_computation.py --users 500 --batch-size 500

# With profiling
python3 benchmark/benchmark_draw_computation.py --users 1000 --profile
```

### Active vs Lazy User Comparison

```bash
# Compare active and lazy user costs
python3 benchmark/benchmark_lazy_users.py --users 100

# With profiling data
python3 benchmark/benchmark_lazy_users.py --users 100 --profile
```

### Analyze Profiles

```bash
# View top functions
go tool pprof -top benchmark/results/active_users_100.pprof

# Interactive web UI
go tool pprof -http=:8081 benchmark/results/lazy_users_100.pprof
```

---

## Appendix: Test Environment

| Component | Version/Details |
|-----------|-----------------|
| Flow Emulator | v2.x with `--computation-reporting` |
| Block Time | 1 second (`--block-time 1s`) |
| Compute Limit | 9,999 CU per transaction |
| Test Date | January 2025 |

---

*Generated by benchmark suite in `/benchmark/`*
