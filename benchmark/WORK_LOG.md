# Benchmark Development Work Log

This log tracks the progress of developing the computation-profiling benchmark for PrizeLinkedAccounts draw operations.

## Goal
Find the upper limit on how many users can be processed in a single `processPoolDrawBatch` transaction to enable efficient manual draws when a round ends.

## Session History

### Session 1 (2026-01-14 ~10:44)
**Status**: Initial implementation created

**What was done**:
1. Created `benchmark/benchmark_draw_computation.py` - comprehensive Python benchmark script
2. Created `benchmark/transactions/setup_benchmark_users.cdc` - transaction to create N simulated users
3. Ran initial test with 10 users, batch size 10

**Results from initial run**:
```json
{
  "user_count": 10,
  "batch_size": 10,
  "phases": [
    {"phase_name": "startPoolDraw", "computation": 73, "tx_count": 1},
    {"phase_name": "processDrawBatch", "computation": 73, "tx_count": 1, "computation_per_item": 7.3}
  ]
}
```

**Issues identified**:
- Only 2 of 4 phases completed (missing requestDrawRandomness and completePoolDraw)
- Need to investigate why phases 3 and 4 didn't run
- Computation values seem low (73 units) - may need to verify computation reporting is working

**Next steps for Session 2**:
1. Debug why requestDrawRandomness and completePoolDraw phases didn't run
2. Verify computation reporting is accurate
3. Run a complete 4-phase benchmark with 10 users
4. Scale up: 50 → 100 → 250 → 500 → 1000 users
5. Find the maximum users per batch before hitting Flow's ~9,999 computation limit

---

### Session 2 (2026-01-14)
**Status**: Completed - All 4 phases working, linear scaling verified

**Investigation completed**:
- [x] Why benchmark stopped after 2 phases
  - Root cause: Phases 3 & 4 likely failed silently due to error handling not adding failed phases to results
  - Also: computation extraction from emulator HTTP API was unreliable
- [x] Verify transaction paths are correct - All paths verified
- [x] Check if emulator computation reporting is working - HTTP API unreliable, switched to JSON tx output

**Changes made to `benchmark_draw_computation.py`**:
1. Modified `run_flow_tx()` to use `--output json` for reliable parsing
2. Extract computation directly from transaction result JSON (`computationUsed` field)
3. Added `get_draw_status()` helper with proper JSON parsing fallback
4. Improved error logging throughout
5. Added more verbose output during benchmark phases
6. Fixed return value unpacking (4 values instead of 3)

**Bug fix**: Added `startIndex` parameter to `setup_benchmark_users.cdc` to prevent user overwriting when creating users in batches > 50.

**Verification test results (10 users)**:
All 4 phases completed successfully:
- startPoolDraw: 38 computation units
- processDrawBatch: 43 units (4.30 per user)
- requestDrawRandomness: 8 units
- completePoolDraw: 4 units
- **Total: 93 units**

---

### Session 3 (2026-01-14 - Current)
**Status**: In progress - Scaling tests to find computation limit

**Scaling test results**:

| Users | processDrawBatch | Comp/User | startPoolDraw | Total |
|-------|-----------------|-----------|---------------|-------|
| 10    | 43              | 4.30      | 38            | 93    |
| 50    | 178             | 3.56      | 61            | 251   |
| 100   | 340             | 3.40      | 88            | 440   |

**Linear scaling analysis**:

The computation scales approximately linearly with a small fixed overhead:

| User Increase | Computation Increase | Expected (linear) |
|---------------|---------------------|-------------------|
| 10 → 50 (5×)  | 43 → 178 (4.1×)     | 5×                |
| 50 → 100 (2×) | 178 → 340 (1.9×)    | 2×                |
| 10 → 100 (10×)| 43 → 340 (7.9×)     | 10×               |

**Linear model fit**:
- Fixed overhead: ~10 computation units
- Per-user cost: ~3.4 computation units
- Formula: `computation ≈ 10 + (3.4 × users)`

**Theoretical maximum** (at 9,999 limit): ~2,938 users per batch

**Scaling tests completed**:

| Users | processDrawBatch | Comp/User | Status |
|------:|----------------:|----------:|:------:|
| 500   | 1,609           | 3.22      | ✅ |
| 1,000 | 3,250           | 3.25      | ✅ |
| 2,000 | 6,460           | 3.23      | ✅ |
| 3,000 | 9,768           | 3.26      | ✅ |
| 3,050 | 9,905           | 3.25      | ✅ |
| 3,075 | 9,948           | 3.24      | ✅ |
| 3,080 | exceeded        | -         | ❌ |

**Conclusion**: Maximum batch size is **~3,075 users** within 9,999 computation limit.

**Recommended batch sizes**:
- Aggressive: 3,000 users/batch
- Safe: 2,500 users/batch
- Conservative: 2,000 users/batch

---

### Session 3 Summary
**Status**: COMPLETED

**Key findings**:
1. Computation scales linearly: `computation ≈ 10 + (3.25 × users)`
2. Maximum single-batch size: ~3,075 users
3. The `processPoolDrawBatch` is the limiting phase
4. Other phases (requestRandomness, completeDraw) are constant cost

**Files generated**:
- `benchmark/BENCHMARK_RESULTS.md` - Full results documentation
- `benchmark/generate_chart.py` - Chart generation script (requires matplotlib)
- `benchmark/results/benchmark_results.json` - Raw data

---

### Session 4 (2026-01-14 - Current)
**Status**: In progress - Benchmarking completeDraw with multiple winners

**Goal**: Find maximum number of winners that can be processed in a single `completeDraw()` transaction.

**Background**: The previous sessions focused on `processPoolDrawBatch()`. The user requested exploring `completeDraw()` which iterates through all winners to:
- Withdraw prize from lottery pool
- Mint shares for winner (auto-compound)
- Update TWAB in active round
- Re-deposit to yield source
- Track lifetime prizes
- Emit events

**Files created**:
- `benchmark/transactions/create_multi_winner_pool.cdc` - Creates pool with PercentageSplit distribution for N winners
- `benchmark/benchmark_complete_draw.py` - Python benchmark for testing completeDraw scaling

**Technical challenges encountered**:
1. Initial benchmark showed 0 computation - Flow CLI JSON doesn't include `computationUsed` field
2. Fixed by using emulator HTTP API at `/emulator/computationReport`
3. First tests showed very low computation (4 units for 10 winners) - no prize money in pool
4. Fixed by adding `fund_lottery_pool()` step to add FLOW to lottery before draw

**Preliminary results** (completeDraw phase only):

| Winners | Computation | Comp/Winner | Notes |
|--------:|------------:|------------:|-------|
| 10      | 57          | 5.70        | Initial test with funded prizes |
| 50      | 2,186       | 43.72       | Per-winner cost increases significantly |
| 100     | ~2,191      | ~21.91      | Need to verify |

**Key observation**: The per-winner cost is NOT constant - it varies significantly:
- 10 winners: 5.70 per winner
- 50 winners: 43.72 per winner

This suggests completeDraw has non-linear scaling, possibly due to:
1. Weighted winner selection algorithm complexity
2. PRNG (Xorshift128plus) operations for multiple winners
3. Share minting calculations becoming more expensive with more existing shares
4. TWAB update complexity

**Current status**: Running scaling tests.

**Debugging session (Session 4 continued)**:

**Bug discovered**: The emulator's `/emulator/computationProfile/reset` API has a bug that causes a nil pointer panic:
```
runtime error: invalid memory address or nil pointer dereference
github.com/onflow/cadence/runtime.(*ComputationProfile).Reset(...)
```

This was causing computation values to be stale/cached - explaining why we saw identical values (2186) for different winner counts.

**Fix applied**: Updated `benchmark_complete_draw.py` to:
1. Disabled the broken reset API call
2. Now matches computation by exact transaction ID from the computation report
3. Added small delay after transaction to ensure computation report is updated

**Verified results after fix** (10 winners):
```
Phase 1: startPoolDraw      - 61 computation units
Phase 2: processDrawBatch   - 177 units (50 users)
Phase 3: requestDrawRandomness - 19 units
Phase 4: completePoolDraw   - 57 units (5.70 per winner)
```

**Scaling test results (Manual tests with fresh emulator each time)**:

| Winners | Total Computation | Per Winner | Notes |
|--------:|------------------:|-----------:|-------|
| 20      | 55                | 2.75       | Clean measurement ✅ |
| 100     | 95                | 0.95       | Low, consistent ✅ |
| 125     | 9,547             | 76.38      | HUGE JUMP ⚠️ |
| 150     | 115               | 0.77       | Low again, inconsistent |
| 175     | 126               | 0.72       | Low again |
| 200     | 18,550            | 92.75      | HUGE JUMP ⚠️ |

**Key observation**: The computation values are HIGHLY INCONSISTENT. Some tests show extremely high values (9,547 for 125 winners, 18,550 for 200 winners) while others with similar winner counts show low values (~95-126).

**Possible causes for inconsistency**:
1. **Winner selection algorithm**: The weighted random selection may have variable complexity depending on the random numbers generated
2. **Xorshift128plus PRNG state**: Different random sequences may result in different loop iterations
3. **Share distribution**: When many winners have similar weights, the algorithm may need more iterations
4. **Floating-point precision**: Edge cases in weight calculations

**Technical issue with automated scaling test**:
The `--scale-test` mode in `benchmark_complete_draw.py` has a bug: it creates new pools for each winner count test, but the user storage paths collide. Users are stored at `/storage/benchmarkUser_{index}`, so the second pool doesn't get any users (the paths are already occupied from the first pool). Only the first test in the sequence gets valid results.

**Current status**: PAUSED - Needs investigation

---

### Session 4 Summary (End of Day) - UPDATED
**Status**: ROOT CAUSE IDENTIFIED ✅

**What was accomplished**:
1. Fixed the emulator computation profile reset API crash (disabled broken reset, using TX ID matching)
2. Ran manual tests with fresh emulator per test
3. Discovered inconsistent computation results for completeDraw
4. **Used computation PROFILING (not just reporting) to analyze call stacks**
5. **IDENTIFIED ROOT CAUSE of variable computation**

**Key findings**:
1. `completeDraw` computation is NOT linear with winner count
2. Results are highly variable - same winner count can produce very different computation
3. **ROOT CAUSE**: The `selectWinners` function uses **LINEAR SEARCH** instead of binary search

**Profiling comparison (125 winners)**:

| Run | Computation | `selectWinners` % | `getWeight` % |
|-----|-------------|-------------------|---------------|
| LOW | 37-106      | negligible        | negligible    |
| HIGH| 9,400+      | 40.07%            | 23.88%        |

**The Problem (PrizeLinkedAccounts.cdc lines 2801-2811)**:
```cadence
for i in InclusiveRange(0, receiverCount - 1) {
    if selectedIndices[i] != nil { continue }
    let weight = self.getWeight(at: i)
    runningSum = runningSum + weight
    if randomValue < runningSum {
        selectedIdx = i
        break  // ← Early exit depends on random value!
    }
}
```

**Why computation varies**:
- The loop breaks when `randomValue < runningSum`
- **Small random value** → finds winner early → **LOW computation**
- **Large random value** (close to total weight) → scans ALL users → **HIGH computation**

For 125 winners with 175 users:
- **Best case**: ~22K iterations (random consistently hits early users)
- **Worst case**: ~21,875+ iterations (random consistently hits late users)

**Recommended Fix**:
Replace linear search with **binary search** on `cumulativeWeights` array. The array is already sorted (cumulative sums are monotonically increasing), so binary search would reduce complexity from **O(winners × users)** to **O(winners × log(users))**.

---

### Session 4 Final Update (2026-01-14 ~21:30)
**Status**: COMPLETED ✅

**Additional work completed**:
1. Created comprehensive findings document: `benchmark/BENCHMARK_FINDINGS.md`
2. Rewrote `benchmark/benchmark_complete_draw.py` with full profiling support

**New benchmark script features**:
- `--runs N` - Run same config multiple times to measure variability
- `--profile` - Enable computation profiling and save pprof files
- `--analyze-profile PATH` - Analyze existing profile without running tests
- Unique user storage paths per pool (fixes collision bug)
- Computation level classification (LOW/MEDIUM/HIGH)
- Variability statistics (min, max, mean, ratio)
- Auto-saves profiles to `benchmark/profiles/` directory
- Timestamped result files in `benchmark/results/`

**Usage examples**:
```bash
# Single test
python3 benchmark/benchmark_complete_draw.py --winners 50 --users 100

# Variability test (multiple runs)
python3 benchmark/benchmark_complete_draw.py --winners 125 --users 175 --runs 5

# With profiling (saves pprof files)
python3 benchmark/benchmark_complete_draw.py --winners 125 --users 175 --runs 3 --profile

# Analyze existing profile
python3 benchmark/benchmark_complete_draw.py --analyze-profile benchmark/profiles/profile.pprof
```

**Files created/modified in Session 4**:
- `benchmark/transactions/create_multi_winner_pool.cdc` - Creates pool with PercentageSplit for N winners
- `benchmark/benchmark_complete_draw.py` - Full rewrite with profiling support
- `benchmark/BENCHMARK_FINDINGS.md` - Comprehensive findings document
- `benchmark/WORK_LOG.md` - This file

**Key deliverables**:
1. **processDrawBatch limit**: ~3,075 users max (recommend 2,500 for safety)
2. **completeDraw issue**: Variable computation due to linear search in `selectWinners`
3. **Recommended fix**: Replace linear search with binary search on cumulative weights

---

### Session 5 (2026-01-14)
**Status**: COMPLETED ✅

**Goal**: Add computation profiling support to `benchmark_draw_computation.py` for `processDrawBatch` analysis.

**Changes made to `benchmark_draw_computation.py`**:
1. Added `--profile` flag to enable `--computation-profiling` on emulator
2. Added `--runs N` flag for multiple runs (variability analysis)
3. Added `--analyze-profile PATH` flag for standalone profile analysis
4. Added `download_computation_profile()` function to save pprof files
5. Added `analyze_profile()` function using `go tool pprof`
6. Added `print_profile_analysis()` for pretty-printed output
7. Disabled broken emulator reset API (same fix as Session 4)
8. Profiles saved to `benchmark/profiles/` with timestamps

**Usage examples**:
```bash
# Basic benchmark (computation reporting only)
python3 benchmark/benchmark_draw_computation.py --users 500 --batch-size 500

# With profiling (saves pprof files)
python3 benchmark/benchmark_draw_computation.py --users 1000 --batch-size 1000 --profile

# Multiple runs for variability analysis
python3 benchmark/benchmark_draw_computation.py --users 2000 --batch-size 2000 --runs 3 --profile

# Analyze existing profile
python3 benchmark/benchmark_draw_computation.py --analyze-profile benchmark/profiles/profile.pprof
```

**Next steps**:
1. ~~Run `processDrawBatch` profiling to identify optimization opportunities~~ ✅
2. ~~Compare call stacks between small and large user counts~~ ✅
3. ~~Document any hotspots found in BENCHMARK_FINDINGS.md~~ ✅

---

### Session 5 Continued - processDrawBatch Deep Analysis
**Status**: COMPLETED ✅

**Profiling run**: 1000 users, single batch with `--computation-profiling`

**Internal call breakdown** (211M total computation):
```
processDrawBatch (100%)
├── finalizeTWAB         44.82%  ◀ Main hotspot
├── Loop overhead        34.67%
├── getBonusWeight        9.22%
├── getUserShares         9.22%
└── addEntry              2.05%
```

**Root cause**: 5 dictionary lookups per user
- `finalizeTWAB`: 3 lookups (userAccumulatedTWAB, userLastUpdateTime, userSharesAtLastUpdate)
- `getUserShares`: 1 lookup
- `getBonusWeight`: 1 lookup

**Optimizations identified**:
| Priority | Optimization | Expected Savings |
|----------|--------------|------------------|
| High | Combine TWAB dictionaries into single struct | 15-25% |
| Medium | Early skip zero-share users | 5-10% |
| Medium | Batch user data retrieval | 5-10% |
| Low | Cache round end time | 1-2% |

**Total potential savings**: 25-45%

**Updated files**:
- `benchmark/BENCHMARK_FINDINGS.md` - Added optimization section
- `benchmark/profiles/process_batch_1000users_run1_*.pprof` - Profiling data

---

## Key Metrics to Collect

| Phase | What it does | Expected computation scaling |
|-------|--------------|------------------------------|
| startPoolDraw | Move ended round to pending, create new round | O(1) - constant |
| processDrawBatch | Finalize TWAB for N users, build weight array | O(N) - linear with batch size |
| requestDrawRandomness | Request on-chain randomness, materialize yield | O(1) - constant |
| completePoolDraw | Select winners, distribute prizes | O(winners) - linear with winner count |

## Computation Limits

- **Flow Mainnet**: ~9,999 computation units per transaction
- **Emulator default**: configurable via `--compute-limit`
- **Goal**: Find max `N` for processDrawBatch where computation < 9,999

## Notes

- Virtual offset (0.0001) for inflation attack protection
- TWAB normalization happens during batch processing
- Each user's final weight = shares × (time_held / round_duration)
