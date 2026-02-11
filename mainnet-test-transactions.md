# Mainnet Deployment — Transaction Log

## Phase 1: mainnet-test-deployer (`0xcc9dd0c6477a8fc7`)

> Initial attempt — pivoted to mainnet-deployer due to beta badge access issues.

### 1. Fund account with FLOW

**Transaction**: `cadence/transactions/fund_account.cdc`

```bash
flow transactions send cadence/transactions/fund_account.cdc \
  0xcc9dd0c6477a8fc7 <amount> \
  --network mainnet \
  --signer <funded-account>
```

**Purpose**: Send FLOW to mainnet-test-deployer to cover storage and transaction fees.

**Status**: Done

---

### 2. Set up pyUSD vault

**Transaction**: `cadence/transactions/setup_pyusd_vault.cdc`

```bash
flow transactions send cadence/transactions/setup_pyusd_vault.cdc \
  --network mainnet \
  --signer mainnet-test-deployer
```

**Purpose**: Create an empty pyUSD vault on mainnet-test-deployer with receiver and balance capabilities.

**Status**: Done

---

### 3. Transfer pyUSD to mainnet-test-deployer

**Transaction**: `cadence/transactions/transfer_pyusd.cdc`

```bash
flow transactions send cadence/transactions/transfer_pyusd.cdc \
  0xcc9dd0c6477a8fc7 5.0 \
  --network mainnet \
  --signer <source-account>
```

**Purpose**: Send 5 pyUSD tokens from a source account to mainnet-test-deployer.

**Status**: Done

---

### 4. Deploy PrizeLinkedAccounts + FlowYieldVaultsConnector to mainnet-test-deployer

```bash
flow project deploy --network mainnet
```

**Purpose**: Deploy both contracts to `0xcc9dd0c6477a8fc7`.

**Status**: Done

---

### 5. Claim beta badge (FAILED)

**Transaction**: `cadence/transactions/claim_beta.cdc`

```bash
flow transactions send cadence/transactions/claim_beta.cdc \
  d2580caf2ef07c2f \
  --network mainnet \
  --signer mainnet-test-deployer
```

**Purpose**: Claim the FlowYieldVaultsClosedBeta.BetaBadge capability from the inbox.

**Status**: Failed — "No beta capability found in inbox". Badge was not published to this account.

---

## Phase 2: mainnet-deployer (`0xa092c4aab33daeda`)

> Pivoted to this account which already has BetaBadge, YieldVaultManager, pyUSD vault, and existing contracts.

### Existing state at `0xa092c4aab33daeda`

**Contracts**: PrizeSavings, FlowYieldVaultsConnector (V1), Xorshift128plus, RandomConsumer, PrizeVaultScheduler, PrizeWinnerTracker, TestHelpers

**Storage**: PrizeSavings.Admin, BetaBadge cap, YieldVaultManager, YieldVaultManagerWrapper (V1), pyUSD vault, FlowToken vault, RandomConsumer.Consumer, PrizeWinnerTracker, PoolPositionCollection

### 6. Deploy FlowYieldVaultsConnectorV2 + PrizeLinkedAccounts

```bash
flow project deploy --network mainnet
```

**Purpose**: Deploy `FlowYieldVaultsConnectorV2` (secured with `Operate` entitlement) and `PrizeLinkedAccounts` to `0xa092c4aab33daeda`.

**Status**: Done

---

### 7. Create pyUSD pool with FlowYieldVaultsConnectorV2

**Transaction**: `cadence/transactions/create_pool_pyusd_mainnet.cdc`

```bash
flow transactions send cadence/transactions/create_pool_pyusd_mainnet.cdc \
  1.0 604800.0 0.35 0.65 0.0 \
  --network mainnet \
  --signer mainnet-deployer \
  --gas-limit 9999
```

**Parameters** (adjust as needed):
- `minimumDeposit`: 1.0 pyUSD
- `drawIntervalSeconds`: 604800.0 (7 days)
- `rewardsPercent`: 0.35 (35% savings)
- `prizePercent`: 0.65 (65% lottery)
- `protocolFeePercent`: 0.0 (0% treasury)

**Purpose**: Create PrizeLinkedAccounts pool using V2 connector with pyUSD + PMStrategiesV1.FUSDEVStrategy. Creates the YieldVaultManagerWrapper, issues entitled capabilities, and wires everything together.

**Status**: Pending

---

### 8. Fund prize pool directly

**Transaction**: `cadence/transactions/prize-linked-accounts/fund_prize_pool.cdc`

```bash
flow transactions send cadence/transactions/prize-linked-accounts/fund_prize_pool.cdc \
  0 <amount> \
  "EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750Vault" \
  "Initial prize pool funding" \
  --network mainnet \
  --signer mainnet-deployer \
  --gas-limit 9999
```

**Parameters**:
- `poolID`: 0
- `amount`: pyUSD amount to add to prize pool
- `vaultPath`: `"EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750Vault"`
- `purpose`: Description string for audit trail

**Purpose**: Directly fund the prize pool with pyUSD tokens. Tokens are deposited into the yield source and tracked as `allocatedPrizeYield` (available for the next draw). Requires admin access (`CriticalOps` entitlement).

**Status**: Pending

---

## Next Steps (not yet run)

- Set up user position collection
- Deposit pyUSD into the pool
