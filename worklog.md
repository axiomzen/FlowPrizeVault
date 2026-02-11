# Worklog: Mainnet Deployment Checklist for PrizeLinkedAccounts

## Current Session - 2025-02-10

### Objectives
- Create projected balance implementation spec (future contract upgrade)
- Create backend migration guide (PrizeSavings → PrizeLinkedAccounts)

### Progress
- Created `docs/PROTOCOL_REFERENCE.md` — comprehensive protocol reference for anyone
  - 22 sections covering every mechanism: shares, yield, TWAB, draws, winner selection,
    randomness, prize distribution, deficits, emergency system, registration, slippage,
    sponsors, NFT prizes, direct funding, protocol fees, invariants, entitlements
  - Full query reference and events reference
  - Replaced old `BACKEND_CONTEXT.md` (too narrow in scope)
- Created `docs/PROJECTED_BALANCE.md` — implementation spec for real-time balance queries
  - `ShareTracker.previewAccrueYield()` — pure dust calculation
  - Refactored `accrueYield()` to delegate to preview
  - `Pool.previewDeficitImpactOnRewards()` — deficit waterfall preview
  - `Pool.getProjectedUserBalance()` — full projected balance
  - Contract-level convenience function
- Created `docs/BACKEND_MIGRATION_GUIDE.md` — migration reference for backend team
  - Contract name change, storage paths, deposit signature (maxSlippageBps)
  - 4-phase draw cycle with state query functions
  - Terminology renames, event changes, pool query functions
  - References only contract-level functions/variables (no repo scripts)

### Next Steps
- User to review both markdown files
- Implement projected balance functions as contract upgrade (pending review)
- Continue mainnet deployment: create pool (step 7), fund prize pool (step 8)

---

## Previous Sessions

### 2025-02-09
- Analyzed both mainnet accounts (0xa092c4aab33daeda and 0x262cf58c0b9fbcff)
- Identified 7 contracts already deployed at target account
- Built deployment checklist, resolved naming conflicts
- Created `fund_prize_pool.cdc` transaction, `get_pyusd_balance.cdc` script
- Updated `admin/COMMANDS.md` with new operations
- Debugged withdrawal dust threshold + FlowYieldVaults rounding issue
- Iterated on backend migration guide (3 rounds of feedback)
- Designed projected balance architecture with shared preview functions
