# PrizeLinkedAccounts Draw Computation Benchmark

Tools for measuring and analyzing computation costs of lottery draw operations on the Flow blockchain.

## Quick Start

```bash
# Run main benchmark with 100 users
python3 benchmark/benchmark_draw_computation.py --users 100 --batch-size 100

# Compare active vs lazy user costs
python3 benchmark/benchmark_lazy_users.py --users 100

# Run with profiling (saves pprof files for detailed analysis)
python3 benchmark/benchmark_draw_computation.py --users 500 --batch-size 500 --profile

# Skip emulator setup if already running
python3 benchmark/benchmark_draw_computation.py --users 500 --skip-setup
```

## Key Findings

| Metric | Active Users | Lazy Users |
|--------|-------------|------------|
| **Computation per user** | ~3.25 CU | ~4.35 CU |
| **Max users per batch** | ~3,075 | ~2,300 |
| **Recommended batch size** | 2,500 | 1,900 |

**Lazy users** (deposited in previous round, no activity this round) cost **~34% more** than active users.

**Recommendation**: Use conservative batch size of **2,000 users** to handle any mix.

**Flow CU limit**: 9,999 per transaction

See [COMPUTATION_ANALYSIS.md](./COMPUTATION_ANALYSIS.md) for **comprehensive analysis with charts**.
See [BENCHMARK_RESULTS.md](./BENCHMARK_RESULTS.md) for raw test results.
See [BENCHMARK_FINDINGS.md](./BENCHMARK_FINDINGS.md) for detailed optimization recommendations.

## Directory Structure

```
benchmark/
├── README.md                          # This file
├── COMPUTATION_ANALYSIS.md            # ◀ Comprehensive analysis with charts
├── BENCHMARK_RESULTS.md               # Test results and data tables
├── BENCHMARK_FINDINGS.md              # Detailed optimization recommendations
├── WORK_LOG.md                        # Development history (optional reading)
├── benchmark_draw_computation.py      # Main benchmark script
├── benchmark_lazy_users.py            # Active vs lazy user cost comparison
├── benchmark_complete_draw.py         # completeDraw-specific benchmarks
├── generate_chart.py                  # Chart generation utility
├── transactions/
│   ├── create_multi_winner_pool.cdc   # Creates test pool with multiple winners
│   └── setup_benchmark_users.cdc      # Creates simulated users for testing
└── results/
    ├── benchmark_results.json         # Raw results (JSON format)
    ├── benchmark_results.csv          # Raw results (CSV format)
    ├── active_users_*.pprof           # Profiling data for active users
    └── lazy_users_*.pprof             # Profiling data for lazy users
```

## Output Files

After running the benchmark, results are saved to:

| File | Format | Description |
|------|--------|-------------|
| `results/benchmark_results.json` | JSON | Detailed per-phase breakdown with memory usage |
| `results/benchmark_results.csv` | CSV | Tabular format for spreadsheet analysis |

### JSON Output Example

```json
{
  "timestamp": "2026-01-22T14:07:16",
  "user_count": 100,
  "batch_size": 100,
  "total_computation": 436,
  "phases": [
    {"phase_name": "startPoolDraw", "total_computation": 90},
    {"phase_name": "processDrawBatch", "total_computation": 334, "computation_per_item": 3.34},
    {"phase_name": "requestDrawRandomness", "total_computation": 8},
    {"phase_name": "completePoolDraw", "total_computation": 4}
  ]
}
```

## Draw Phases Explained

The lottery draw consists of 4 sequential phases:

| Phase | Description | Computation |
|-------|-------------|-------------|
| 1. `startPoolDraw` | Initialize draw, move round to pending | ~50-90 CU (scales slightly with users) |
| 2. `processDrawBatch` | Finalize TWAB for each user | **~3.25 CU per user** |
| 3. `requestDrawRandomness` | Request on-chain random number | ~8-20 CU (constant) |
| 4. `completePoolDraw` | Select winners, distribute prizes | Variable (see findings) |

## Command Line Options

```
--users N           Number of users to benchmark (default: 100)
--batch-size N      Users processed per batch in Phase 2 (default: 50)
--winners N         Number of winners per draw (default: 1)
--runs N            Number of benchmark runs (default: 1)
--profile           Enable pprof profiling for detailed analysis
--skip-setup        Skip emulator startup (use existing instance)
--analyze-profile   Analyze existing pprof file without running benchmark
```

## Requirements

- Python 3.8+
- Flow CLI v2.x
- No additional Python packages required (uses standard library only)

## Profiling with pprof

For detailed function-level analysis:

```bash
# Run with profiling enabled
python3 benchmark/benchmark_draw_computation.py --users 1000 --batch-size 1000 --profile

# Analyze the generated profile
go tool pprof -top benchmark/results/*.pprof
go tool pprof -http=:8081 benchmark/results/*.pprof  # Web UI
```

## Manual Emulator Setup

If you prefer to run the emulator separately:

```bash
# Terminal 1: Start emulator
flow emulator --block-time 1s --computation-reporting

# Terminal 2: Run benchmark (skip auto-setup)
python3 benchmark/benchmark_draw_computation.py --users 500 --skip-setup
```
