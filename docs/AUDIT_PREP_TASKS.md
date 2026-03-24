# Audit Preparation Task List

> Produce auditor-facing docs in `docs/audit/`. Each is standalone, concise, and skimmable.
> AUDIT_CHECKLIST.md is unchanged — it's a reusable template for any Cadence contract.
> Existing docs (ACCOUNTING.md, TWAB.md) are referenced, not duplicated.

---

## Writing Style

- Tables over paragraphs
- No filler, no hedging, no "it should be noted that"
- State facts. If something is a risk, say so directly.
- If a section would exceed ~150 lines, split or trim

---

## Phase 1: Auditor Documents

### 1. `docs/audit/OVERVIEW.md`
- [ ] What the contract does (3-4 sentences)
- [ ] Scope: PrizeLinkedAccounts.cdc vs FlowYieldVaultsConnectorV2.cdc vs external
- [ ] Happy-path user flows (setup -> deposit -> yield -> prize -> withdraw)
- [ ] Actors table: user, sponsor, admin (ConfigOps/CriticalOps), owner (OwnerOnly)

### 2. `docs/audit/ARCHITECTURE.md`
- [ ] Resource table: 5 resources, what each owns
- [ ] Interface table: 3 strategy interfaces
- [ ] Entitlement table: 4 entitlements, what each guards
- [ ] Storage/capability paths table with access level
- [ ] Resource lifecycle: creation, movement, destruction

### 3. `docs/audit/STATE_MACHINES.md`
- [ ] Pool states: Normal / Paused / EmergencyMode / PartialMode — transitions table
- [ ] Draw phases: Idle -> start -> batch -> randomness -> complete — transitions table
- [ ] Auto-trigger and auto-recovery conditions
- [ ] What operations are blocked per state/phase

### 4. `docs/audit/ECONOMIC_MODEL.md`
- [ ] Token flow: deposits -> yield source -> three-way split
- [ ] Three-way split: rewards (share price up) / lottery (prize pool) / treasury (fees)
- [ ] Sponsor flow (yield, no prizes)
- [ ] Deficit socialization order: protocol fee -> prize -> rewards
- [ ] Reference ACCOUNTING.md for share price math

### 5. `docs/audit/PRECISION.md`
- [ ] UFix64 constraints (8 decimals, range, no negatives)
- [ ] Virtual offset formula and dust implications
- [ ] Where rounding occurs and in whose favor
- [ ] PR #55 context (PercentageSplit rounding overflow)
- [ ] Cross-check ACCOUNTING.md vs current code

### 6. `docs/audit/RANDOMNESS.md`
- [ ] RandomConsumer: Flow commit-reveal, guarantees
- [ ] Xorshift128plus: seeding, state space, PR #53 fix
- [ ] Winner selection: weighted random from TWAB
- [ ] Manipulation resistance (reference TWAB.md)
- [ ] Bonus weight effect on selection

### 7. `docs/audit/BATCH_PROCESSING.md`
- [ ] Why batching exists (Cadence execution limits)
- [ ] processDrawBatch() mechanics: size, progress, completion
- [ ] Swap-and-pop index management
- [ ] Unregistration blocked during draws (why)
- [ ] Intermission period purpose

### 8. `docs/audit/TRUST_MODEL.md`
- [ ] Dependency table: each external contract, what we assume, failure mode
- [ ] What happens if yield source returns less / is unavailable
- [ ] Adversarial model: what users can and cannot do

### 9. `docs/audit/CRITICAL_FUNCTIONS.md`
- [ ] Table per function: signature, preconditions, what could go wrong
- [ ] Cover: deposit, withdraw, all 4 draw phases, sync, emergency, fee, NFT ops

### 10. `docs/audit/INVARIANTS.md`
- [ ] Each invariant: statement, where enforced, how to try to break it
- [ ] Cover: accounting balance, TWAB cap, share price, state machine, round timing

### 11. `docs/audit/RISK_ANALYSIS.md`
- [ ] Known risks table: risk, mitigation
- [ ] DoS/griefing vectors: analysis and mitigations
- [ ] Recently fixed bugs: PR #53, #55, #56 — what broke, what was fixed

### 12. `docs/audit/EVENT_CATALOG.md`
- [ ] Events grouped by category with emitting function
- [ ] Flag any state-changing function missing an event

### 13. `docs/audit/TESTING_GUIDE.md`
- [ ] How to run tests (commands)
- [ ] Test file table: file -> what it covers
- [ ] Coverage results
- [ ] Known gaps

### 14. `docs/audit/RECOVERY.md`
- [ ] Stuck draw, yield source failure, bad config, emergency procedures
- [ ] Upgrade/migration constraints

---

## Phase 2: Verification

- [ ] Run Cadence linter, address findings
- [ ] Audit `access(all)` functions for unintended mutation
- [ ] Audit force-unwrap (`!`) and cast (`as!`) usage
- [ ] Scan for debug code / TODOs in critical paths
- [ ] Run `make test` and `make test-all` — record results
- [ ] Run `make test-cover` — record coverage
- [ ] Verify docs match code (invariants, paths, events, entitlements)
- [ ] Record commit hash in all documents

---

## Phase 3: Package

- [ ] Create `docs/audit/README.md` — reading order and index
- [ ] Verify cross-references between documents
- [ ] Final read: can an unfamiliar auditor follow everything?

---

| Phase | Output | Count |
|-------|--------|-------|
| 1 | Standalone audit docs | 14 |
| 2 | Code verification | 8 |
| 3 | Packaging | 3 |
| **Total** | | **25** |
