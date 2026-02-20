/*
FlowYieldVaultsConnectorV2 - Mainnet FlowYieldVaults Integration (Secured)

PURPOSE: Connector for EVM-bridged tokens with 6 decimal precision (e.g., pyUSD).
The EVM-Cadence bridge truncates to 6 decimals on withdrawal, while Cadence's UFix64
has 8 decimals. This connector truncates amounts before bridge calls to prevent panics.

DO NOT use this connector for tokens with different decimal precision.
For tokens with 8+ decimals (e.g., native FLOW), use a connector without truncation
or create a new connector with the appropriate precision.

Security model:
- The YieldVaultManagerWrapper resource is stored in the deployer's account
- A PUBLIC capability exposes only getYieldVaultBalance() for read-only queries
- An ENTITLED capability (auth(Operate)) gates depositToYieldVault/withdrawFromYieldVault
- The Connector struct holds the entitled capability internally, so only the contract
  that stores the Connector (PrizeLinkedAccounts) can trigger deposit/withdraw operations

FlowYieldVaults Contract: mainnet://b1d63873c3cc9f79.FlowYieldVaults
*/

import FungibleToken from 0xf233dcee88fe0abe
import FlowYieldVaults from 0xb1d63873c3cc9f79
import FlowYieldVaultsClosedBeta from 0xb1d63873c3cc9f79
import DeFiActions from 0x92195d814edf9cb0
import DeFiActionsUtils from 0x92195d814edf9cb0

access(all) contract FlowYieldVaultsConnectorV2 {

    /// Entitlement required to deposit/withdraw through the YieldVaultManagerWrapper.
    /// Only the Connector struct (living inside PrizeLinkedAccounts' Pool) holds a capability with this entitlement.
    access(all) entitlement Operate

    // Storage paths
    access(all) let ManagerStoragePath: StoragePath
    access(all) let ManagerPublicPath: PublicPath

    // Events
    access(all) event ConnectorCreated(managerAddress: Address, strategyType: String, vaultType: String)
    access(all) event DepositedToYieldVault(yieldVaultID: UInt64, amount: UFix64, vaultType: String)
    access(all) event WithdrawnFromYieldVault(yieldVaultID: UInt64, amount: UFix64, vaultType: String)
    access(all) event YieldVaultCreated(yieldVaultID: UInt64, strategyType: String, initialAmount: UFix64)

    /// YieldVaultManagerWrapper Resource
    /// Wraps FlowYieldVaults.YieldVaultManager with beta badge authentication.
    ///
    /// - getYieldVaultBalance() is access(all) — callable via the public capability for read-only queries
    /// - depositToYieldVault() and withdrawFromYieldVault() require the Operate entitlement
    access(all) resource YieldVaultManagerWrapper {
        access(self) let yieldVaultManagerCap: Capability<auth(FungibleToken.Withdraw) &FlowYieldVaults.YieldVaultManager>
        access(self) let betaBadgeCap: Capability<auth(FlowYieldVaultsClosedBeta.Beta) &FlowYieldVaultsClosedBeta.BetaBadge>
        access(self) var yieldVaultID: UInt64?
        access(all) let vaultType: Type
        access(all) let strategyType: Type

        init(
            yieldVaultManagerCap: Capability<auth(FungibleToken.Withdraw) &FlowYieldVaults.YieldVaultManager>,
            betaBadgeCap: Capability<auth(FlowYieldVaultsClosedBeta.Beta) &FlowYieldVaultsClosedBeta.BetaBadge>,
            vaultType: Type,
            strategyType: Type
        ) {
            pre {
                yieldVaultManagerCap.check(): "Invalid YieldVaultManager capability"
                betaBadgeCap.check(): "Invalid Beta badge capability"
            }

            self.yieldVaultManagerCap = yieldVaultManagerCap
            self.betaBadgeCap = betaBadgeCap
            self.vaultType = vaultType
            self.strategyType = strategyType
            self.yieldVaultID = nil
        }

        /// Deposit tokens into the yield vault. Requires Operate entitlement.
        access(Operate) fun depositToYieldVault(from: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}) {
            pre {
                from.getType() == self.vaultType: "Vault type mismatch"
                from.balance > 0.0: "Cannot deposit zero balance"
            }

            let amount = from.balance
            let yieldVaultManager = self.yieldVaultManagerCap.borrow()
                ?? panic("Cannot borrow YieldVaultManager")
            let betaBadge = self.betaBadgeCap.borrow()
                ?? panic("Cannot borrow Beta badge")

            // If we don't have a YieldVault yet, create one
            if self.yieldVaultID == nil {
                let initialVault <- from.withdraw(amount: amount)

                let newID = yieldVaultManager.createYieldVault(
                    betaRef: betaBadge,
                    strategyType: self.strategyType,
                    withVault: <- initialVault
                )

                self.yieldVaultID = newID

                emit YieldVaultCreated(
                    yieldVaultID: self.yieldVaultID!,
                    strategyType: self.strategyType.identifier,
                    initialAmount: amount
                )

                emit DepositedToYieldVault(
                    yieldVaultID: self.yieldVaultID!,
                    amount: amount,
                    vaultType: self.vaultType.identifier
                )
            } else {
                let depositVault <- from.withdraw(amount: amount)

                yieldVaultManager.depositToYieldVault(
                    betaRef: betaBadge,
                    self.yieldVaultID!,
                    from: <- depositVault
                )

                emit DepositedToYieldVault(
                    yieldVaultID: self.yieldVaultID!,
                    amount: amount,
                    vaultType: self.vaultType.identifier
                )
            }
        }

        /// Query the current balance in the yield vault. Publicly accessible (read-only).
        access(all) fun getYieldVaultBalance(): UFix64 {
            if self.yieldVaultID == nil {
                return 0.0
            }

            let yieldVaultManager = self.yieldVaultManagerCap.borrow()
                ?? panic("Cannot borrow YieldVaultManager")

            let yieldVaultRef = yieldVaultManager.borrowYieldVault(id: self.yieldVaultID!)
            if yieldVaultRef == nil {
                return 0.0
            }

            return yieldVaultRef!.getYieldVaultBalance()
        }

        /// Withdraw tokens from the yield vault. Requires Operate entitlement.
        access(Operate) fun withdrawFromYieldVault(maxAmount: UFix64): @{FungibleToken.Vault} {
            pre {
                self.yieldVaultID != nil: "No YieldVault initialized"
                maxAmount > 0.0: "Cannot withdraw zero amount"
            }

            let yieldVaultManager = self.yieldVaultManagerCap.borrow()
                ?? panic("Cannot borrow YieldVaultManager")

            let available = self.getYieldVaultBalance()
            let withdrawAmount = maxAmount < available ? maxAmount : available

            assert(withdrawAmount > 0.0, message: "Insufficient balance in YieldVault")

            let vault <- yieldVaultManager.withdrawFromYieldVault(self.yieldVaultID!, amount: withdrawAmount)

            emit WithdrawnFromYieldVault(
                yieldVaultID: self.yieldVaultID!,
                amount: withdrawAmount,
                vaultType: vault.getType().identifier
            )

            return <- vault
        }
    }

    /// Connector Struct
    /// Implements DeFiActions.Sink and DeFiActions.Source.
    ///
    /// Holds an entitled capability (auth(Operate)) to the YieldVaultManagerWrapper for deposit/withdraw,
    /// and uses the public capability for balance queries.
    /// Once this struct is stored inside PrizeLinkedAccounts' Pool (access(contract) field),
    /// only PrizeLinkedAccounts can trigger deposit/withdraw operations.
    access(all) struct Connector: DeFiActions.Sink, DeFiActions.Source {
        access(all) let managerAddress: Address
        access(self) let operateCap: Capability<auth(Operate) &YieldVaultManagerWrapper>
        access(contract) var uniqueID: DeFiActions.UniqueIdentifier?
        access(all) let vaultType: Type

        init(
            managerAddress: Address,
            operateCap: Capability<auth(Operate) &YieldVaultManagerWrapper>,
            vaultType: Type
        ) {
            pre {
                operateCap.check(): "Invalid Operate capability for YieldVaultManagerWrapper"
            }
            self.managerAddress = managerAddress
            self.operateCap = operateCap
            self.vaultType = vaultType
            self.uniqueID = nil
        }

        /// DeFiActions.Sink Implementation — deposits through the entitled capability
        access(all) fun depositCapacity(from: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}) {
            let managerRef = self.operateCap.borrow()
                ?? panic("Cannot borrow YieldVaultManagerWrapper via Operate capability")

            managerRef.depositToYieldVault(from: from)
        }

        access(all) view fun getSinkType(): Type {
            return self.vaultType
        }

        access(all) view fun minimumCapacity(): UFix64 {
            return 0.0
        }

        /// DeFiActions.Source Implementation — balance via public path, withdraw via entitled capability
        access(all) fun minimumAvailable(): UFix64 {
            let managerAccount = getAccount(self.managerAddress)
            if let managerRef = managerAccount.capabilities.borrow<&YieldVaultManagerWrapper>(
                FlowYieldVaultsConnectorV2.ManagerPublicPath
            ) {
                return FlowYieldVaultsConnectorV2.truncateTo6DecimalPrecision(
                    managerRef.getYieldVaultBalance()
                )
            }
            return 0.0
        }

        access(FungibleToken.Withdraw) fun withdrawAvailable(maxAmount: UFix64): @{FungibleToken.Vault} {
            let managerRef = self.operateCap.borrow()
                ?? panic("Cannot borrow YieldVaultManagerWrapper via Operate capability")

            let truncatedAmount = FlowYieldVaultsConnectorV2.truncateTo6DecimalPrecision(maxAmount)
            if truncatedAmount == 0.0 {
                // Sub-6-decimal dust — bridge can't move this. Return empty vault.
                return <- DeFiActionsUtils.getEmptyVault(self.vaultType)
            }
            return <- managerRef.withdrawFromYieldVault(maxAmount: truncatedAmount)
        }

        access(all) view fun getSourceType(): Type {
            return self.vaultType
        }

        /// DeFiActions Component Info
        access(all) fun getComponentInfo(): DeFiActions.ComponentInfo {
            return DeFiActions.ComponentInfo(
                type: self.getType(),
                id: self.uniqueID?.id,
                innerComponents: []
            )
        }

        access(contract) view fun copyID(): DeFiActions.UniqueIdentifier? {
            return self.uniqueID
        }

        access(contract) fun setID(_ id: DeFiActions.UniqueIdentifier?) {
            self.uniqueID = id
        }
    }

    /// Create a new YieldVaultManagerWrapper and store it.
    /// Returns a Connector struct that holds an entitled capability for deposit/withdraw.
    /// A read-only public capability is also published for balance queries.
    access(all) fun createConnectorAndManager(
        account: auth(Storage, Capabilities) &Account,
        yieldVaultManagerCap: Capability<auth(FungibleToken.Withdraw) &FlowYieldVaults.YieldVaultManager>,
        betaBadgeCap: Capability<auth(FlowYieldVaultsClosedBeta.Beta) &FlowYieldVaultsClosedBeta.BetaBadge>,
        vaultType: Type,
        strategyType: Type
    ): Connector {
        // Validate that the strategy supports the vault type
        let supportedVaults = FlowYieldVaults.getSupportedInitializationVaults(forStrategy: strategyType)
        assert(
            supportedVaults[vaultType] == true,
            message: "Strategy does not support vault type"
        )

        // Create and store the YieldVaultManagerWrapper resource
        let manager <- create YieldVaultManagerWrapper(
            yieldVaultManagerCap: yieldVaultManagerCap,
            betaBadgeCap: betaBadgeCap,
            vaultType: vaultType,
            strategyType: strategyType
        )

        account.storage.save(<-manager, to: self.ManagerStoragePath)

        // Issue entitled capability for the Connector (NOT published — only the Connector holds it)
        let operateCap = account.capabilities.storage.issue<auth(Operate) &YieldVaultManagerWrapper>(self.ManagerStoragePath)

        // Publish read-only capability for public balance queries
        let publicCap = account.capabilities.storage.issue<&YieldVaultManagerWrapper>(self.ManagerStoragePath)
        account.capabilities.publish(publicCap, at: self.ManagerPublicPath)

        emit ConnectorCreated(
            managerAddress: account.address,
            strategyType: strategyType.identifier,
            vaultType: vaultType.identifier
        )

        // Return the struct connector that holds the entitled capability
        return Connector(
            managerAddress: account.address,
            operateCap: operateCap,
            vaultType: vaultType
        )
    }

    /// Truncates a UFix64 value to 6 decimal places for EVM-bridged tokens (e.g., pyUSD).
    /// The EVM-Cadence bridge only supports 6 decimals; passing 8-decimal UFix64 values
    /// causes bridge panics. This floors DOWN — never over-reports or over-requests.
    /// Overflow-safe for any UFix64 value by separating integer/fractional parts.
    access(all) view fun truncateTo6DecimalPrecision(_ value: UFix64): UFix64 {
        if value == 0.0 { return 0.0 }

        let PRECISION_FACTOR: UFix64 = 1000000.0  // 10^6 for 6 decimals

        // Split into integer + fractional to avoid overflow.
        let integerPart: UFix64 = UFix64(UInt64(value))
        let fractionalPart: UFix64 = value - integerPart

        let scaledFrac: UFix64 = fractionalPart * PRECISION_FACTOR
        let truncatedFrac: UInt64 = UInt64(scaledFrac)  // Floor (truncate toward zero)

        return integerPart + UFix64(truncatedFrac) / PRECISION_FACTOR
    }

    init() {
        let identifier = "flowYieldVaultsManagerV2_\(self.account.address)"
        self.ManagerStoragePath = StoragePath(identifier: identifier)!
        self.ManagerPublicPath = PublicPath(identifier: identifier)!
    }
}
