# Testing Guide

Contract: `PrizeLinkedAccounts.cdc`

## Commands

| Command | What It Runs | When To Use |
|---------|-------------|-------------|
| `make test` | `flow test cadence/tests/*_test.cdc` | Development iteration, CI fast path |
| `make test-all` | `flow test cadence/tests/*_test.cdc cadence/long_tests/*_test.cdc` | Pre-merge, release validation |
| `make test-long` | `flow test cadence/long_tests/*_test.cdc` | Stress testing only |
| `make test-cover` | `flow test cadence/tests/*_test.cdc --cover` | Coverage reporting |
| `make test-all-cover` | All tests + `--cover` | Full coverage report |
| `flow test cadence/tests/RoundTWAB_test.cdc` | Single file | Fastest iteration on one area |
| `flow test ... 2>&1 \| grep -E "^(Test results:\|- PASS\|- FAIL)"` | Any test with log suppression | Cleaner output |

## Test Coverage

### Fast Tests (`cadence/tests/`)

| File | Area |
|------|------|
| `AdminResource_test.cdc` | Admin entitlements, access control |
| `BatchDraw_test.cdc` | Batch draw phases, completion |
| `BatchProcessingAdvanced_test.cdc` | Large batch edge cases |
| `BonusWeightDraws_test.cdc` | Bonus weight in draws |
| `DecimalPrecision_test.cdc` | UFix64 precision boundaries |
| `DeficitHandling_test.cdc` | Deficit waterfall, insolvency |
| `DepositCapacityOverflow_test.cdc` | TVL cap enforcement |
| `DepositSlippage_test.cdc` | Slippage protection, bps calc |
| `DistributionStrategy_test.cdc` | Yield split strategies |
| `DistributionThreshold_test.cdc` | Minimum distribution threshold |
| `DrawPhaseInteraction_test.cdc` | Deposits/withdrawals during draw |
| `EmergencyConfig_test.cdc` | Emergency states, auto-recovery |
| `GapPeriod_test.cdc` | Gap between round end and startDraw |
| `Intermission_test.cdc` | Post-draw intermission behavior |
| `MultiRoundSequence_test.cdc` | Sequential round transitions |
| `NFTPrizeManagement_test.cdc` | NFT deposit, award, claim |
| `NormalizedTWABEdgeCases_test.cdc` | TWAB normalization edge cases |
| `PoolCreation_test.cdc` | Pool initialization, config |
| `PoolDepositsWithdraws_test.cdc` | Core deposit/withdraw flows |
| `PoolDraws_test.cdc` | End-to-end draw lifecycle |
| `PoolEntries_test.cdc` | Entry/weight calculation |
| `PoolInitialState_test.cdc` | Initial pool state invariants |
| `PoolPositionCollection_test.cdc` | Position resource lifecycle |
| `PoolStateMachine_test.cdc` | State transitions validation |
| `PrizeLinkedAccounts_test.cdc` | Integration / smoke tests |
| `ProjectedBalance_test.cdc` | Projected balance with unsync'd yield |
| `ProtocolFeeManagement_test.cdc` | Fee forwarding, unclaimed vault |
| `RoundEdgeCases_test.cdc` | Round boundary conditions |
| `RoundTargetEndTime_test.cdc` | Target end time updates |
| `RoundTWAB_test.cdc` | TWAB accumulation, finalization |
| `SharePricePrecision_test.cdc` | Share price rounding, virtual offset |
| `SponsorDeposits_test.cdc` | Sponsor deposits, prize ineligibility |
| `StorageCleanup_test.cdc` | Ghost receiver cleanup, batching |
| `TWABOverflow_single_test.cdc` | Single-user TWAB overflow |
| `TWABOverflow_test.cdc` | Multi-user TWAB overflow |
| `WinnerSelectionStrategy_test.cdc` | Winner selection algorithms |

### Support Files

| File | Purpose |
|------|---------|
| `test_helpers.cdc` | Shared test utilities, setup |

### Long Tests (`cadence/long_tests/`)

| File | Area |
|------|------|
| `SharePricePrecision_long_test.cdc` | Extended share price stress test |

## Known Gaps

- No fuzz testing for PRNG seed expansion or winner selection distribution uniformity.
- No test for concurrent multi-pool operations (single contract, multiple pools simultaneously).
- No test for `PoolPositionCollection` resource destruction (funds become inaccessible).
- No test for `SponsorPositionCollection` resource destruction.
- No test covering protocol fee recipient vault type mismatch at draw time (documented failure mode in `setPoolProtocolFeeRecipient`).
- No test for draw with exactly `WEIGHT_WARNING_THRESHOLD` weight (only a runtime guardrail).
- No adversarial test for deposit-right-before-startDraw timing (TWAB should handle this, but no explicit attack scenario test).
- No test for admin capability delegation with minimal entitlements (ConfigOps-only vs CriticalOps).
- Long test suite has only 1 file; stress testing coverage is limited.
- No gas/computation limit testing for batch processing with very large receiver counts.
