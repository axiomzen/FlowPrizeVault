# Worklog: EVM Bridge Decimal Precision Fix

## Current Session - 2026-02-19

### Objectives
- Implement expanded fork test edge cases for the decimal precision fix
- Create query scripts and transactions for comprehensive testing

### Progress
- Created 4 fork-test query scripts (string imports for mainnet-fork):
  - `cadence/scripts/fork-test/get_yield_status.cdc` — yield/accounting invariant checks
  - `cadence/scripts/fork-test/get_user_shares.cdc` — detailed share breakdown
  - `cadence/scripts/fork-test/is_registered.cdc` — registration status
  - `cadence/scripts/fork-test/get_draw_status.cdc` — draw state machine status
- Created 2 fork-test transactions (string imports):
  - `cadence/transactions/fork-test/deposit_pyusd.cdc` — re-deposit pyUSD into pool
  - `cadence/transactions/fork-test/start_draw_full.cdc` — smart draw state machine advancement
- Updated `FORK_TEST_GUIDE.md` with 7 test scenarios:
  1. Contract update sanity check (no state change)
  2. Partial withdrawal (user keeps position)
  3. Sequential partial withdrawals (dust accumulation)
  4. Full withdrawal with deep accounting verification
  5. Deposit → withdraw round-trip
  6. Draw cycle through truncated connector
  7. Boundary amount withdrawals (6-decimal precision edge)
- Verified flow.json is valid
- Note: The `get_user_balance.cdc` bug mentioned in plan (`borrowPool(id:)`) doesn't exist in current code — it already uses `getProjectedUserBalance(poolID:)` correctly

### Next Steps
- Start emulator fork: `flow emulator --fork mainnet --fork-height 142781958`
- Run through all 7 scenarios in FORK_TEST_GUIDE.md
- Key invariant at every step: `|yieldSourceBalance - totalAllocatedFunds| < 0.000001`

---

## Previous Sessions

### Session 2 - 2026-02-19 (Fork Setup)
- Fixed trailing comma in flow.json
- Verified flow.json state: mainnet aliases for PrizeLinkedAccounts + FlowYieldVaultsConnectorV2
- All fork-test scripts/transactions in place
- Awaiting user to restart emulator fork for testing

### Session 1 - Implementation
- Implemented EVM bridge decimal precision fix in FlowYieldVaultsConnectorV2.cdc
  - Added `truncateTo6DecimalPrecision()` utility function
  - Modified `minimumAvailable()` and `withdrawAvailable()` to truncate before bridge calls
  - Added `import "DeFiActionsUtils"` for empty vault creation
- Created test infrastructure (TruncatingVaultConnector mock, 11 tests in DecimalPrecision_test.cdc)
- All tests passing
- Renamed function from `truncateToAssetPrecision` to `truncateTo6DecimalPrecision` per user feedback
- Generated PR description
- Set up fork testing config in flow.json
- Created FORK_TEST_GUIDE.md with step-by-step instructions
- Commit: 3708fd5 (Fix Precision in FYV)
