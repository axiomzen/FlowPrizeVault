# PrizeLinkedAccounts Draw Computation Benchmark Results

**Date**: 2026-01-14
**Goal**: Find maximum users per `processPoolDrawBatch` transaction within Flow's 9,999 computation limit

---

## Summary

| Metric | Value |
|--------|-------|
| **Maximum batch size** | ~3,075 users |
| **Safe recommended batch size** | 2,500-3,000 users |
| **Computation per user** | ~3.25 units |
| **Fixed overhead** | ~10 units |

---

## Benchmark Parameters

```
Network:        Flow Emulator
Compute Limit:  9,999 units (Flow mainnet default)
Deposit Amount: 10.0 FLOW per user
Draw Interval:  1 second (for fast testing)
```

---

## Results Table

| Users | processDrawBatch | Comp/User | Batches | Status |
|------:|----------------:|----------:|--------:|:------:|
| 10    | 43              | 4.30      | 1       | ✅ |
| 50    | 178             | 3.56      | 1       | ✅ |
| 100   | 340             | 3.40      | 1       | ✅ |
| 500   | 1,609           | 3.22      | 1       | ✅ |
| 1,000 | 3,250           | 3.25      | 1       | ✅ |
| 2,000 | 6,460           | 3.23      | 1       | ✅ |
| 3,000 | 9,768           | 3.26      | 1       | ✅ |
| 3,050 | 9,905           | 3.25      | 1       | ✅ |
| 3,075 | 9,948           | 3.24      | 1       | ✅ |
| 3,080 | exceeded        | -         | 6       | ❌ |
| 3,090 | exceeded        | -         | 6       | ❌ |
| 3,100 | exceeded        | -         | 6       | ❌ |

---

## Computation Scaling Visualization

```
Computation Units (processDrawBatch phase)
│
│ 9,999 ┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈ LIMIT
│                                                    ╱
│ 9,000                                           ▓▓▓ 3,075: 9,948
│                                                ╱
│ 8,000                                        ╱
│                                             ╱
│ 7,000                                     ╱
│                                    ▓▓▓▓▓▓  2,000: 6,460
│ 6,000                            ╱
│                                 ╱
│ 5,000                         ╱
│                              ╱
│ 4,000                      ╱
│                     ▓▓▓▓▓▓  1,000: 3,250
│ 3,000                ╱
│                     ╱
│ 2,000              ╱
│              ▓▓▓▓▓  500: 1,609
│ 1,000       ╱
│            ╱
│     ▓▓▓▓▓▓  100: 340
│    ╱
│ ▓▓  10: 43
└───────────────────────────────────────────────────────────► Users
    0    500   1000   1500   2000   2500   3000   3500
```

---

## Linear Scaling Model

The computation scales **linearly** with user count:

```
computation = 10 + (3.25 × users)
```

### Model Verification

| Users | Predicted | Actual | Error |
|------:|----------:|-------:|------:|
| 100   | 335       | 340    | +1.5% |
| 500   | 1,635     | 1,609  | -1.6% |
| 1,000 | 3,260     | 3,250  | -0.3% |
| 2,000 | 6,510     | 6,460  | -0.8% |
| 3,000 | 9,760     | 9,768  | +0.1% |

---

## Recommendations

### For Production Use

| Pool Size | Recommended Batch Size | Batches Needed |
|----------:|----------------------:|---------------:|
| 1,000     | 1,000                 | 1              |
| 5,000     | 2,500                 | 2              |
| 10,000    | 2,500                 | 4              |
| 50,000    | 2,500                 | 20             |
| 100,000   | 2,500                 | 40             |

### Safety Margins

- **Aggressive**: 3,000 users/batch (leaves ~230 units buffer)
- **Recommended**: 2,500 users/batch (leaves ~1,875 units buffer)
- **Conservative**: 2,000 users/batch (leaves ~3,540 units buffer)

---

## Other Phases (Constant Cost)

| Phase | Computation | Notes |
|-------|-------------|-------|
| startPoolDraw | ~1,700 @ 3k users | Scales slightly with user count |
| requestDrawRandomness | 8 | Constant |
| completePoolDraw | 4 | Constant (single winner) |

---

## How to Run

```bash
# Run benchmark with specific user count
python3 benchmark/benchmark_draw_computation.py --users 1000 --batch-size 1000

# Skip emulator setup (if already running)
python3 benchmark/benchmark_draw_computation.py --users 500 --skip-setup
```

---

## Files

- `benchmark/benchmark_draw_computation.py` - Main benchmark script
- `benchmark/transactions/setup_benchmark_users.cdc` - User creation transaction
- `benchmark/results/benchmark_results.json` - Raw results (JSON)
- `benchmark/results/benchmark_results.csv` - Raw results (CSV)
