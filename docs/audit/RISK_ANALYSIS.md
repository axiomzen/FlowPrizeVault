# Risk Analysis

All references to `cadence/contracts/PrizeLinkedAccounts.cdc`.

## Known Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| Malicious yield connector steals deposited funds | Critical | Yield connector is immutable after pool creation (`let yieldConnector`). Admin `createPool` with `CriticalOps` is the only path. Auditors should verify connector implementations separately. |
| Admin key compromise redirects protocol fees | High | `setProtocolFeeRecipient` requires `OwnerOnly` entitlement which cannot be delegated via capability. Multi-sig recommended for admin account. |
| Admin changes distribution strategy mid-round to divert yield | High | `updatePoolDistributionStrategy` requires `CriticalOps`. Takes effect on next `syncWithYieldSource`, not retroactively. Events emitted for monitoring. No time-lock mechanism. |
| Admin changes prize distribution after `startDraw` but before `completeDraw` | Medium | `updatePoolPrizeDistribution` has no lock during active draw. A change between `startDraw` and `completeDraw` alters winner count and prize splits for the current draw. |
| Yield source returns manipulated `minimumAvailable()` | High | `syncWithYieldSource` trusts this value for all accounting. A fabricated excess inflates rewards/prizes; a fabricated deficit socializes phantom losses. |
| PoolPositionCollection resource destruction loses all funds | High | By design -- resource ownership model. No admin recovery mechanism. Documented in code with security warnings. |
| Virtual offset dust accumulates in protocol fee | Low | ~0.0001 per yield accrual event. Routed to `allocatedProtocolFee` and forwarded or stored in unclaimed vault. Economically negligible. |
| UFix64 precision loss in percentage-based distribution | Low | `FixedPercentageStrategy` gives protocol fee the remainder (`totalAmount - rewards - prize`). PercentageSplit gives last winner the remainder. Both avoid underflow. |
| Prize carry-forward on no-winner draw | Low | If no eligible participants, `allocatedPrizeYield` is not zeroed -- it carries to the next draw. Intentional behavior. |
| `startDraw` asserts `allocatedPrizeYield > 0` | Medium | If no yield has accrued (e.g., 0% APY yield source), draw cannot proceed. Admin must use `fundPoolDirect(destination: Prize)` to seed prize pool. |

## DoS/Griefing Vectors

| Vector | Feasibility | Mitigation |
|--------|-------------|------------|
| Spam deposits to inflate `registeredReceiverList` and increase batch gas cost | Low | `minimumDeposit` enforced. Batch processing uses `limit` parameter -- admin controls gas per tx. Snapshot count at `startDraw` prevents new deposits from extending batch. |
| Deposit-then-withdraw during batch processing to create ghost entries | Low | Ghost entries (0 shares) get 0 weight in `finalizeTWAB`. Cleaned up via `cleanupPoolStaleEntries` after draw. No prize impact. |
| Calling `processDrawBatch(limit: 0)` to stall draw | None | `limit >= 0` precondition allows 0, but cursor doesn't advance and `remaining` stays the same. Any caller can send a proper batch. Draw functions are permissionless. |
| Depositing minimum amount right before draw to dilute prize weight | Low | TWAB normalizes by hold duration. A last-second deposit yields near-zero weight. Attacker pays gas for negligible prize odds. |
| Triggering emergency mode via consecutive withdrawal failures | Medium | Requires yield source to fail withdrawals `maxWithdrawFailures` times (default 3). Attacker would need to control or compromise the yield source. Auto-recovery enabled by default. |
| Repeatedly calling `startDraw` permissionlessly after round ends | None | `startDraw` sets `pendingDrawReceipt` -- subsequent calls hit `pendingDrawReceipt == nil` precondition. Only one draw can be active. |
| Admin-created pools with no depositors consuming storage | Low | Pool creation requires `CriticalOps`. No pool count limit, but deployer account pays storage. Cleanup not implemented for empty pools. |

## Recently Fixed Bugs

| PR | Bug | Impact | Fix |
|----|-----|--------|-----|
| #53 | PRNG seed expansion duplicated the same 8-byte seed as both `s0` and `s1`, collapsing Xorshift128plus state space from 2^128 to 2^64 | Reduced randomness entropy for winner selection. With `s0 == s1`, the PRNG period and distribution quality degrade. Predictability of winner selection increased. | XOR the seed with the golden ratio constant (`0x9e3779b97f4a7c15`) to produce a distinct `s1`, ensuring the full 2^128 state space is utilized. File: `PrizeLinkedAccounts.cdc` line ~2821. |
| #55 | `PercentageSplit.distributePrizes` computed `totalPrizeAmount - calculatedSum` for the last winner without overflow protection. UFix64 rounding across many small percentage splits could cause `calculatedSum > totalPrizeAmount`, underflowing and panicking. | `completeDraw` would revert permanently for any pool using `PercentageSplit` with many winners and small splits. Draw bricked -- prizes locked until admin changed distribution strategy. | Guard the last-winner remainder: `if calculatedSum >= totalPrizeAmount { append 0.0 } else { append remainder }`. File: `PrizeLinkedAccounts.cdc` line ~2327. |
| #56 | `withdrawUnclaimedProtocolFee` used `recipient.check()` as precondition then `recipient.borrow()!` in the body. Between the check and the force-unwrap, the capability could become invalid (TOCTOU race). | Force-unwrap panic during admin fee withdrawal. Funds not lost (still in unclaimed vault) but admin operation blocked until retry. | Replace pattern with `recipient.borrow() ?? panic("Failed to borrow recipient capability")`. Remove redundant `check()` precondition. File: `PrizeLinkedAccounts.cdc` line ~1148. |
