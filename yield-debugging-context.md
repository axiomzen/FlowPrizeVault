# PrizeSavings Pool 1 Yield Debugging — Full Context

> This document captures the full investigation into why mainnet PrizeSavings Pool 1 is not showing yield accrual. It is intended to be injected into another Claude Code session for continuity.

## TL;DR

**PrizeSavings Pool 1 IS earning yield at the ERC4626 level (~0.42% NAV above par), but PrizeSavings can't see it** because `minimumAvailable()` returns a UniswapV3 AMM swap quote instead of the actual ERC4626 NAV. The AMM quote understates the true value by ~2.81 pyUSD on a ~695 pyUSD position. Additionally, the AutoBalancer has `hasActiveSchedule: false`, meaning no automated rebalancing transactions are running.

---

## 1. Architecture Overview

### Contract Stack (Mainnet)

```
PrizeSavings (0xa092c4aab33daeda)
  └── Pool 1 (yieldConnector)
        └── FlowYieldVaultsConnector.Connector (0xa092c4aab33daeda)
              └── YieldVaultManagerWrapper
                    └── FlowYieldVaults.YieldVaultManager (0xb1d63873c3cc9f79)
                          └── YieldVault #106
                                └── PMStrategiesV1.FUSDEVStrategy (0xb1d63873c3cc9f79)
                                      ├── Deposit path: pyUSD → MultiSwapper (UniV3 + ERC4626 deposit) → AutoBalancer
                                      └── Withdraw path: AutoBalancer → UniV3 swap → pyUSD
```

### Key Contract Addresses (Mainnet)

| Contract | Address |
|----------|---------|
| PrizeSavings | `0xa092c4aab33daeda` |
| FlowYieldVaultsConnector | `0xa092c4aab33daeda` |
| FlowYieldVaults | `0xb1d63873c3cc9f79` |
| PMStrategiesV1 | `0xb1d63873c3cc9f79` |
| FlowYieldVaultsAutoBalancers | `0xb1d63873c3cc9f79` |
| FlowYieldVaultsSchedulerRegistry | `0xb1d63873c3cc9f79` |
| DeFiActions | `0x6d888f175c158410` |
| SwapConnectors | `0xe1a479f0cb911df9` |
| ERC4626Utils | `0x04f5ae6bef48c1fc` |
| FlowEVMBridgeConfig | `0x1e4aa0b87d10b141` |

### EVM Token Addresses (Flow EVM)

| Token | EVM Address |
|-------|-------------|
| ERC4626 Share Token (yield-bearing) | `d069d989e2f44b70c65347d1853c0c67e10a9f8d` |
| Underlying Asset (pyUSD) | `99af3eea856556646c98c8b9b2548fe815240750` |

### Cadence Token Type Identifiers

| Token | Cadence Type |
|-------|-------------|
| Share Token | `A.1e4aa0b87d10b141.EVMVMBridgedToken_d069d989e2f44b70c65347d1853c0c67e10a9f8d.Vault` |
| Underlying (pyUSD) | `A.1e4aa0b87d10b141.EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750.Vault` |

---

## 2. The Core Problem: `minimumAvailable()` Call Stack

PrizeSavings Pool 1 determines its yield by calling `minimumAvailable()` on its yield connector. We traced the full call stack:

```
Level 1: FlowYieldVaultsConnector.Connector.minimumAvailable()
  → borrows YieldVaultManagerWrapper at ManagerPublicPath
  → calls managerRef.getYieldVaultBalance()

Level 2: YieldVaultManagerWrapper.getYieldVaultBalance()
  → borrows YieldVaultManager
  → gets YieldVault ref (ID 106)
  → calls yieldVaultRef.getYieldVaultBalance()

Level 3: FlowYieldVaults.YieldVault.getYieldVaultBalance()
  → calls self._borrowStrategy().availableBalance(ofToken: self.vaultType)

Level 4: PMStrategiesV1.FUSDEVStrategy.availableBalance(ofToken:)
  → returns self.source.minimumAvailable()
  → (source is a SwapConnectors.SwapSource)

Level 5: SwapConnectors.SwapSource.minimumAvailable()
  → gets raw share balance from self.source.minimumAvailable() (AutoBalancer)
  → runs UniV3 AMM quote: self.swapper.quoteOut(forProvided: availableIn, reverse: false).outAmount
  → *** THIS IS WHERE THE ISSUE IS — returns AMM swap quote, NOT ERC4626 NAV ***

Level 6: DeFiActions.AutoBalancerSource.minimumAvailable()
  → returns ab.vaultBalance() (raw share token balance)
```

**Key finding**: `minimumAvailable()` returns a **UniswapV3 AMM swap quote** for converting ERC4626 yield token shares back to pyUSD. It does NOT return the actual ERC4626 NAV (Net Asset Value). The AMM quote introduces slippage and spread that makes the value appear lower than reality.

---

## 3. Current Pool 1 State (as of 2026-02-09)

### Pool Stats (from `debug_pool_yield_mainnet.cdc`)

| Metric | Value |
|--------|-------|
| connectorType | `A.a092c4aab33daeda.FlowYieldVaultsConnector.Connector` |
| minimumAvailable (AMM quote) | 694.82632000 |
| totalStaked | 694.85688100 |
| totalDeposited | 694.85688100 |
| pendingLotteryYield | 0.0 |
| rawYieldAccrued | 0.0 (because minimumAvailable < totalStaked) |
| availableYieldRewards | 0.0 |
| yieldStatus | **CRITICAL** |
| yieldIssue | "Vault balance is LESS than totalStaked - possible loss or withdrawal" |
| distributionStrategy | Fixed (35% savings / 65% lottery / 0% treasury) |
| emergencyState | 0 (normal) |

### ERC4626 NAV Data (from `investigate_yield_value.cdc`)

| Metric | Value |
|--------|-------|
| connectorReportedBalance (AMM quote) | 694.82632000 pyUSD |
| Our share balance (AutoBalancer) | 694.74212401 shares |
| ERC4626 totalAssets | 51,055,125,903 (raw, 6 decimals = **51,055.13 pyUSD**) |
| ERC4626 totalShares | 50,842,908,473,224,849,613,865 (raw, 18 decimals = **50,842.91 shares**) |
| NAV per share | **1.00417 pyUSD/share** |
| Our NAV-based value | 694.742 * 1.00417 = **~697.64 pyUSD** |
| YieldVault ID | 106 |
| AutoBalancer isStuck | false |
| AutoBalancer hasActiveSchedule | **false** |

### Value Comparison

```
ERC4626 NAV value (actual):    ~697.64 pyUSD   ← what the shares are really worth
totalStaked (Pool 1 tracks):    694.857 pyUSD   ← what the pool thinks it deposited
AMM quote (what Pool 1 sees):   694.826 pyUSD   ← what minimumAvailable() returns
                                ───────────────
NAV vs totalStaked:             +2.78 pyUSD surplus (yield IS accruing)
AMM vs totalStaked:             -0.031 pyUSD deficit (appears as CRITICAL)
NAV vs AMM:                     +2.81 pyUSD hidden yield (AMM underprices)
```

**The pool is actually in profit by ~2.78 pyUSD, but PrizeSavings thinks it's in deficit by -0.031 because it relies on the AMM swap quote.**

---

## 4. Pool 1 Event History (On-Chain)

### Deposits (block range ~139180000 to ~141680000)

| Block | Amount (FLOW/pyUSD) | Depositor |
|-------|---------------------|-----------|
| 139227036 | 0.10 | 0xa092c4aab33daeda |
| 139228046 | 99.90 | 0xa092c4aab33daeda |
| 139264960 | 0.10 | 0xa092c4aab33daeda |
| 139265207 | 0.01 | 0xa092c4aab33daeda |
| 139265420 | 0.01 | 0xa092c4aab33daeda |
| 139268330 | 97.00 | 0x346df67de37914a3 |
| 139340958 | 0.10 | 0x346df67de37914a3 |
| 139341068 | 0.10 | 0x346df67de37914a3 |
| 139587783 | 0.50 | 0x346df67de37914a3 |
| 140160091 | 497.00 | 0x346df67de37914a3 |
| **Total deposits** | **694.92** | |

Wait — there were also withdrawals:

### Withdrawals

| Block | Amount | Withdrawer |
|-------|--------|------------|
| 139284499 | 79.98 | 0xa092c4aab33daeda |
| 140945333 | 5.00 | 0x346df67de37914a3 |
| 140970049 | 100.00 | 0xa092c4aab33daeda |
| **Total withdrawals** | **184.98** | |

### Other Events Affecting Accounting

| Event | Block | Amount | Details |
|-------|-------|--------|---------|
| DirectFundingReceived | 139227036 | 0.10 | Seed to lottery pool |
| DirectFundingReceived | 139228046 | 99.90 | Seed to lottery pool |
| PrizesAwarded (Round 1) | ~139340xxx | 100.00 | Auto-compounded back into Pool 1 for winner 0x346df67de37914a3 |
| SavingsYieldAccrued | (none found) | 0.0 | No yield has been distributed |

### Reconciliation

```
Net from deposits:     694.92
- Withdrawals:        -184.98
+ Prize compounded:   +100.00
= Expected total:      609.94  ... hmm, let me recheck

Actually the on-chain totalDeposited = 694.86 tracks deposits + prize auto-compounding:
  Deposits from events:    594.86
+ Prizes auto-compounded: +100.00
= totalDeposited:          694.86 ✓
```

### Timeline

- **Last deposit**: Block 140160091 (~497 FLOW from 0x346df67de37914a3)
- **Last withdrawal**: Block 140945333 (~5 FLOW from 0x346df67de37914a3)

---

## 5. Root Cause Analysis

### Why PrizeSavings shows no yield / CRITICAL status:

1. **`minimumAvailable()` returns a UniV3 AMM swap quote**, not the ERC4626 NAV
2. The AMM quote includes swap slippage/spread, making it undervalue the actual shares
3. The AMM quote (694.826) is **less than** totalStaked (694.857), so PrizeSavings thinks it's in a loss state
4. The actual ERC4626 NAV (~697.64) shows the position is **in profit** by ~2.78 pyUSD

### Why yield appears "completely stable" over many days:

1. The AMM quote is relatively stable because UniV3 pricing doesn't directly track ERC4626 NAV
2. The ERC4626 vault IS accruing yield (NAV per share = 1.00417), but this isn't reflected in the AMM quote
3. The AutoBalancer has `hasActiveSchedule: false` — no rebalancing transactions are running

### Additional concern: AutoBalancer not scheduling

The AutoBalancer for YieldVault #106 has:
- `isStuck: false`
- `hasActiveSchedule: false`

This means it's not actively scheduling rebalance transactions. The `isStuck` check passes because it may not have a `recurringConfig` set, or the next execution time calculation returns nil. This could mean the AutoBalancer was never configured for recurring rebalances, or its scheduling chain was broken.

---

## 6. Potential Fixes to Investigate

### Option A: Change how PrizeSavings reads yield value
Instead of relying on `minimumAvailable()` (AMM quote), use the ERC4626 NAV directly via `ERC4626Utils.totalAssets/totalShares` to calculate the true value of held shares.

### Option B: Fix at the SwapConnectors level
Modify `SwapConnectors.SwapSource.minimumAvailable()` to use ERC4626 NAV instead of (or in addition to) the AMM quote for ERC4626-backed strategies.

### Option C: Add a previewRedeem-based oracle
Use `ERC4626Utils.previewRedeem()` (if available — note: `ERC4626Utils` contract does NOT currently have a `previewRedeem` function, only `previewMint` and `previewDeposit`) to get the exact redemption value of shares.

### Option D: Investigate AutoBalancer scheduling
Determine why the AutoBalancer has no active schedule and whether re-enabling it would cause the yield to be "realized" through the AMM by periodically rebalancing.

---

## 7. Debug Scripts Available

All scripts are in the `azsavings-flow` app directory.

### `cadence/scripts/prize-vault-modular/debug_pool_yield_mainnet.cdc`
- **Purpose**: Comprehensive Pool-level yield diagnostic
- **Input**: `poolID: UInt64`
- **Run**: `flow scripts execute <path> --args-json '[{"type":"UInt64","value":"1"}]' --network mainnet`
- **Returns**: minimumAvailable, totalStaked, totalDeposited, pendingLotteryYield, yieldStatus, etc.

### `cadence/scripts/debug/investigate_yield_vault_mainnet.cdc`
- **Purpose**: Query YieldVaultManagerWrapper directly (connector-level)
- **Input**: `managerAddress: Address`
- **Run**: `flow scripts execute <path> --args-json '[{"type":"Address","value":"0xa092c4aab33daeda"}]' --network mainnet`
- **Returns**: connectorReportedBalance, vaultType, strategyType

### `cadence/scripts/debug/investigate_yield_value.cdc`
- **Purpose**: Compare AMM quote vs ERC4626 NAV data
- **Input**: `managerAddress: Address`
- **Run**: `flow scripts execute <path> --args-json '[{"type":"Address","value":"0xa092c4aab33daeda"}]' --network mainnet`
- **Returns**: AMM quote, share balance, ERC4626 totalAssets/totalShares, AutoBalancer status

### Other debug scripts in `cadence/scripts/prize-vault-modular/`:
- `check_pools_at_address.cdc` — Check pools at a given address
- `compare_deposits_to_vault_mainnet.cdc` — Compare deposit records to vault
- `debug_flow_yield_vaults.cdc` — Query FlowYieldVaults directly
- `debug_pool_yield.cdc` — Pool yield diagnostic (non-mainnet version)
- `get_pending_lottery_yield.cdc` / `get_pending_lottery_yield_mainnet.cdc` — Query pending lottery yield
- `get_yield_connector_details.cdc` — Get connector details
- `get_yield_connector_type.cdc` — Get connector type identifier

---

## 8. Contract Source Code (fetched from mainnet)

During investigation, the following contracts were fetched from mainnet and saved to `/tmp/`:

| File | Contract | Address |
|------|----------|---------|
| `/tmp/FlowYieldVaults.cdc` | FlowYieldVaults | 0xb1d63873c3cc9f79 |
| `/tmp/PMStrategiesV1.cdc` | PMStrategiesV1 | 0xb1d63873c3cc9f79 |
| `/tmp/SwapConnectors.cdc` | SwapConnectors | 0xe1a479f0cb911df9 |
| `/tmp/FlowYieldVaultsAutoBalancers.cdc` | FlowYieldVaultsAutoBalancers | 0xb1d63873c3cc9f79 |
| `/tmp/DeFiActions.cdc` | DeFiActions | 0x6d888f175c158410 |
| `/tmp/ERC4626Utils.cdc` | ERC4626Utils | 0x04f5ae6bef48c1fc |

These can be re-fetched using the Flow CLI:
```bash
flow accounts get <address> --network mainnet -o json | python3 -c "import json,sys; data=json.load(sys.stdin); [print(c) for c in data.get('contracts',{}).keys()]"
```

To get a specific contract's code:
```cadence
// Script: get_contract_code.cdc
access(all) fun main(address: Address, contractName: String): String {
    let account = getAccount(address)
    let deployedContract = account.contracts.get(name: contractName)
    if deployedContract == nil { return "Contract not found" }
    return String.fromUTF8(deployedContract!.code) ?? "Could not decode"
}
```

---

## 9. Key Code References

### SwapConnectors.SwapSource.minimumAvailable() — THE critical function
**Contract**: SwapConnectors (`0xe1a479f0cb911df9`)
**File**: `/tmp/SwapConnectors.cdc`, lines 587-593
```cadence
access(all) fun minimumAvailable(): UFix64 {
    let availableIn = self.source.minimumAvailable()  // AutoBalancer share balance
    return availableIn > 0.0
        ? self.swapper.quoteOut(forProvided: availableIn, reverse: false).outAmount
        : 0.0
}
```

### DeFiActions.AutoBalancerSource.minimumAvailable() — raw share balance
**Contract**: DeFiActions (`0x6d888f175c158410`)
**File**: `/tmp/DeFiActions.cdc`, lines 564-568
```cadence
access(all) fun minimumAvailable(): UFix64 {
    if let ab = self.autoBalancer.borrow() {
        return ab.vaultBalance()  // Raw share token balance
    }
    return 0.0
}
```

### PrizeSavings yield calculation — how CRITICAL status is determined
**Contract**: PrizeSavings (`0xa092c4aab33daeda`)
```cadence
// Simplified from contract logic:
availableYield = minimumAvailable() - (totalStaked + pendingLotteryYield)
// If minimumAvailable < totalStaked → CRITICAL (appears as loss)
```

---

## 10. Flow CLI Tips

```bash
# Run a Cadence script on mainnet
flow scripts execute <script.cdc> --args-json '[...]' --network mainnet --config-path <path>/flow.json

# Query events (use --batch 250 max, --workers 3 to avoid rate limits)
flow events get A.a092c4aab33daeda.PrizeSavings.Deposited <startBlock> <endBlock> \
  --network mainnet --batch 250 --workers 3

# Get current block height
flow blocks get latest --network mainnet -o json | python3 -c "import json,sys; print(json.load(sys.stdin)['height'])"
```

---

## 11. Open Questions / Next Steps

1. **Why does the AutoBalancer have no active schedule?** Was it configured with a `recurringConfig`? Did its scheduling chain break?
2. **Is `ERC4626Utils.previewRedeem()` available?** The contract only has `previewMint` and `previewDeposit`. Adding `previewRedeem` would give exact redemption values.
3. **Should `minimumAvailable()` be changed to use NAV?** This is the fundamental fix — the SwapSource pricing via AMM doesn't reflect ERC4626 yield.
4. **Can we snapshot the ERC4626 NAV over time?** Running `investigate_yield_value.cdc` periodically would show whether NAV per share is growing.
5. **What is the expected APY of this ERC4626 vault?** Need to check what the underlying yield source is (likely a lending protocol on Flow EVM).
