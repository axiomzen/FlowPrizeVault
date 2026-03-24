# PrizeLinkedAccounts — Audit Documentation

> Internal audit package for `PrizeLinkedAccounts.cdc` and `FlowYieldVaultsConnectorV2.cdc`.

## Reading Order

Start here, then follow the numbered path. Each document is standalone but builds on prior context.

| # | Document | What You'll Learn |
|---|----------|-------------------|
| 1 | [OVERVIEW](OVERVIEW.md) | What the contract does, scope, user flows, actors |
| 2 | [ARCHITECTURE](ARCHITECTURE.md) | Resources, interfaces, entitlements, storage paths |
| 3 | [STATE_MACHINES](STATE_MACHINES.md) | Pool states, draw phases, emergency auto-triggers |
| 4 | [ECONOMIC_MODEL](ECONOMIC_MODEL.md) | Token flow, three-way yield split, deficit waterfall |
| 5 | [PRECISION](PRECISION.md) | UFix64 limits, virtual offset, rounding behavior |
| 6 | [RANDOMNESS](RANDOMNESS.md) | PRNG, winner selection, manipulation resistance |
| 7 | [BATCH_PROCESSING](BATCH_PROCESSING.md) | Draw batching, index management, intermission |
| 8 | [TRUST_MODEL](TRUST_MODEL.md) | External dependencies, failure modes, adversarial model |
| 9 | [CRITICAL_FUNCTIONS](CRITICAL_FUNCTIONS.md) | Security-sensitive functions, preconditions, risks |
| 10 | [INVARIANTS](INVARIANTS.md) | What must always be true, how to try to break it |
| 11 | [RISK_ANALYSIS](RISK_ANALYSIS.md) | Known risks, DoS vectors, recently fixed bugs |
| 12 | [EVENT_CATALOG](EVENT_CATALOG.md) | All 42 events, grouped by category |
| 13 | [TESTING_GUIDE](TESTING_GUIDE.md) | How to run tests, coverage map, known gaps |
| 14 | [RECOVERY](RECOVERY.md) | Stuck draws, emergency procedures, upgrade constraints |

## Pre-Existing Documentation

These docs predate the audit package and are referenced throughout:

- [ACCOUNTING.md](../ACCOUNTING.md) — Share price math, ERC4626 model, virtual offset
- [TWAB.md](../TWAB.md) — Time-weighted average balance mechanics

## Contract Files

| File | Lines | Role |
|------|-------|------|
| `cadence/contracts/PrizeLinkedAccounts.cdc` | ~5,900 | Main contract |
| `cadence/contracts/FlowYieldVaultsConnectorV2.cdc` | ~500 | Mainnet yield source connector |

## Deployment

| Network | Address | Status |
|---------|---------|--------|
| Emulator | `f8d6e0586b0a20c7` | Development |
| Testnet | `839535ddeb5acf17` | Testing |
| Mainnet | `a092c4aab33daeda` | Pending Audit |
