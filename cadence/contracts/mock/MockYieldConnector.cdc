import "FungibleToken"
import "DeFiActions"
import "DeFiActionsUtils"

/// MockYieldConnector - Simple vault connector for testing PrizeLinkedAccounts
/// Implements DeFiActions.Sink and DeFiActions.Source interfaces to connect
/// to a FlowToken vault stored at /storage/testYieldVault
access(all) contract MockYieldConnector {
    
    /// SimpleVaultConnector - A struct that implements both Sink and Source
    /// by wrapping capabilities to a FungibleToken vault
    access(all) struct SimpleVaultConnector: DeFiActions.Sink, DeFiActions.Source {
        /// Capability to withdraw from the underlying vault
        access(self) let providerCap: Capability<auth(FungibleToken.Withdraw) &{FungibleToken.Provider, FungibleToken.Balance}>
        /// Capability to deposit to the underlying vault
        access(self) let receiverCap: Capability<&{FungibleToken.Receiver}>
        /// The vault type this connector handles
        access(self) let vaultType: Type
        /// UniqueIdentifier for DeFiActions tracing
        access(contract) var uniqueID: DeFiActions.UniqueIdentifier?
        
        init(
            providerCap: Capability<auth(FungibleToken.Withdraw) &{FungibleToken.Provider, FungibleToken.Balance}>,
            receiverCap: Capability<&{FungibleToken.Receiver}>,
            vaultType: Type
        ) {
            self.providerCap = providerCap
            self.receiverCap = receiverCap
            self.vaultType = vaultType
            self.uniqueID = nil
        }
        
        // ============ Sink Interface ============
        
        /// Returns the Vault type accepted by this Sink
        access(all) view fun getSinkType(): Type {
            return self.vaultType
        }
        
        /// Returns an estimate of how much can be deposited (unlimited for this simple connector)
        access(all) fun minimumCapacity(): UFix64 {
            return UFix64.max
        }
        
        /// Deposits funds from the provided vault reference
        access(all) fun depositCapacity(from: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}) {
            if let receiver = self.receiverCap.borrow() {
                let amount = from.balance
                if amount > 0.0 {
                    receiver.deposit(from: <-from.withdraw(amount: amount))
                }
            }
        }
        
        // ============ Source Interface ============
        
        /// Returns the Vault type provided by this Source
        access(all) view fun getSourceType(): Type {
            return self.vaultType
        }
        
        /// Returns the available balance that can be withdrawn
        access(all) fun minimumAvailable(): UFix64 {
            if let provider = self.providerCap.borrow() {
                return provider.balance
            }
            return 0.0
        }
        
        /// Withdraws up to maxAmount from the underlying vault
        access(FungibleToken.Withdraw) fun withdrawAvailable(maxAmount: UFix64): @{FungibleToken.Vault} {
            if let provider = self.providerCap.borrow() {
                let available = provider.balance
                let withdrawAmount = maxAmount < available ? maxAmount : available
                if withdrawAmount > 0.0 {
                    return <-provider.withdraw(amount: withdrawAmount)
                }
            }
            // Return an empty vault if we can't withdraw
            return <-DeFiActionsUtils.getEmptyVault(self.vaultType)
        }
        
        // ============ IdentifiableStruct Interface ============
        
        /// Returns component info for DeFiActions tracing
        access(all) fun getComponentInfo(): DeFiActions.ComponentInfo {
            return DeFiActions.ComponentInfo(
                type: self.getType(),
                id: self.id(),
                innerComponents: []
            )
        }
        
        /// Returns a copy of the UniqueIdentifier
        access(contract) view fun copyID(): DeFiActions.UniqueIdentifier? {
            return self.uniqueID
        }
        
        /// Sets the UniqueIdentifier
        access(contract) fun setID(_ id: DeFiActions.UniqueIdentifier?) {
            self.uniqueID = id
        }
    }
    
    /// Creates a new SimpleVaultConnector
    access(all) fun createSimpleVaultConnector(
        providerCap: Capability<auth(FungibleToken.Withdraw) &{FungibleToken.Provider, FungibleToken.Balance}>,
        receiverCap: Capability<&{FungibleToken.Receiver}>,
        vaultType: Type
    ): SimpleVaultConnector {
        return SimpleVaultConnector(
            providerCap: providerCap,
            receiverCap: receiverCap,
            vaultType: vaultType
        )
    }

    /// LimitedCapacityConnector - A connector with a maximum capacity limit
    /// Used for testing deposit capacity overflow protection
    access(all) struct LimitedCapacityConnector: DeFiActions.Sink, DeFiActions.Source {
        /// Capability to withdraw from the underlying vault
        access(self) let providerCap: Capability<auth(FungibleToken.Withdraw) &{FungibleToken.Provider, FungibleToken.Balance}>
        /// Capability to deposit to the underlying vault
        access(self) let receiverCap: Capability<&{FungibleToken.Receiver}>
        /// The vault type this connector handles
        access(self) let vaultType: Type
        /// Maximum capacity this connector will accept
        access(self) let capacityLimit: UFix64
        /// UniqueIdentifier for DeFiActions tracing
        access(contract) var uniqueID: DeFiActions.UniqueIdentifier?
        init(
            providerCap: Capability<auth(FungibleToken.Withdraw) &{FungibleToken.Provider, FungibleToken.Balance}>,
            receiverCap: Capability<&{FungibleToken.Receiver}>,
            vaultType: Type,
            capacityLimit: UFix64
        ) {
            self.providerCap = providerCap
            self.receiverCap = receiverCap
            self.vaultType = vaultType
            self.capacityLimit = capacityLimit
            self.uniqueID = nil
        }

        // ============ Sink Interface ============

        /// Returns the Vault type accepted by this Sink
        access(all) view fun getSinkType(): Type {
            return self.vaultType
        }

        /// Returns how much more capacity is available (limited by capacityLimit)
        access(all) fun minimumCapacity(): UFix64 {
            if let provider = self.providerCap.borrow() {
                let currentBalance = provider.balance
                if currentBalance >= self.capacityLimit {
                    return 0.0
                }
                return self.capacityLimit - currentBalance
            }
            return self.capacityLimit
        }

        /// Deposits funds from the provided vault reference (up to capacity limit)
        access(all) fun depositCapacity(from: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}) {
            if let receiver = self.receiverCap.borrow() {
                let availableCapacity = self.minimumCapacity()
                let depositAmount = from.balance < availableCapacity ? from.balance : availableCapacity
                if depositAmount > 0.0 {
                    receiver.deposit(from: <-from.withdraw(amount: depositAmount))
                }
            }
        }

        // ============ Source Interface ============

        /// Returns the Vault type provided by this Source
        access(all) view fun getSourceType(): Type {
            return self.vaultType
        }
        /// Returns the available balance that can be withdrawn
        access(all) fun minimumAvailable(): UFix64 {
            if let provider = self.providerCap.borrow() {
                return provider.balance
            }
            return 0.0
        }
        /// Withdraws up to maxAmount from the underlying vault
        access(FungibleToken.Withdraw) fun withdrawAvailable(maxAmount: UFix64): @{FungibleToken.Vault} {
            if let provider = self.providerCap.borrow() {
                let available = provider.balance
                let withdrawAmount = maxAmount < available ? maxAmount : available
                if withdrawAmount > 0.0 {
                    return <-provider.withdraw(amount: withdrawAmount)
                }
            }
            // Return an empty vault if we can't withdraw
            return <-DeFiActionsUtils.getEmptyVault(self.vaultType)
        }

        // ============ IdentifiableStruct Interface ============

        /// Returns component info for DeFiActions tracing
        access(all) fun getComponentInfo(): DeFiActions.ComponentInfo {
            return DeFiActions.ComponentInfo(
                type: self.getType(),
                id: self.id(),
                innerComponents: []
            )
        }
        /// Returns a copy of the UniqueIdentifier
        access(contract) view fun copyID(): DeFiActions.UniqueIdentifier? {
            return self.uniqueID
        }
        /// Sets the UniqueIdentifier
        access(contract) fun setID(_ id: DeFiActions.UniqueIdentifier?) {
            self.uniqueID = id
        }
    }

    /// Creates a new LimitedCapacityConnector with a maximum capacity
    access(all) fun createLimitedCapacityConnector(
        providerCap: Capability<auth(FungibleToken.Withdraw) &{FungibleToken.Provider, FungibleToken.Balance}>,
        receiverCap: Capability<&{FungibleToken.Receiver}>,
        vaultType: Type,
        capacityLimit: UFix64
    ): LimitedCapacityConnector {
        return LimitedCapacityConnector(
            providerCap: providerCap,
            receiverCap: receiverCap,
            vaultType: vaultType,
            capacityLimit: capacityLimit
        )
    }

    /// SlippageVaultConnector - A connector that charges a configurable deposit fee (in basis points)
    /// Used for testing deposit slippage accounting reconciliation.
    /// On deposit, it withdraws the full amount from the source vault, takes a fee,
    /// deposits the remainder into the underlying vault, and sends the fee to a separate sink vault.
    access(all) struct SlippageVaultConnector: DeFiActions.Sink, DeFiActions.Source {
        /// Capability to withdraw from the underlying vault
        access(self) let providerCap: Capability<auth(FungibleToken.Withdraw) &{FungibleToken.Provider, FungibleToken.Balance}>
        /// Capability to deposit to the underlying vault
        access(self) let receiverCap: Capability<&{FungibleToken.Receiver}>
        /// Capability to deposit fees into a separate sink vault
        access(self) let feeSinkCap: Capability<&{FungibleToken.Receiver}>
        /// The vault type this connector handles
        access(self) let vaultType: Type
        /// Deposit fee in basis points (e.g., 200 = 2%)
        access(self) let depositFeeBps: UInt64
        /// UniqueIdentifier for DeFiActions tracing
        access(contract) var uniqueID: DeFiActions.UniqueIdentifier?

        init(
            providerCap: Capability<auth(FungibleToken.Withdraw) &{FungibleToken.Provider, FungibleToken.Balance}>,
            receiverCap: Capability<&{FungibleToken.Receiver}>,
            feeSinkCap: Capability<&{FungibleToken.Receiver}>,
            vaultType: Type,
            depositFeeBps: UInt64
        ) {
            pre {
                depositFeeBps <= 10000: "Fee cannot exceed 100%"
            }
            self.providerCap = providerCap
            self.receiverCap = receiverCap
            self.feeSinkCap = feeSinkCap
            self.vaultType = vaultType
            self.depositFeeBps = depositFeeBps
            self.uniqueID = nil
        }

        // ============ Sink Interface ============

        /// Returns the Vault type accepted by this Sink
        access(all) view fun getSinkType(): Type {
            return self.vaultType
        }

        /// Returns an estimate of how much can be deposited (unlimited for this connector)
        access(all) fun minimumCapacity(): UFix64 {
            return UFix64.max
        }

        /// Deposits funds with a fee deducted.
        /// Withdraws full amount from source vault, deposits (amount - fee) to underlying vault,
        /// sends fee to fee sink vault.
        access(all) fun depositCapacity(from: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}) {
            if let receiver = self.receiverCap.borrow() {
                let amount = from.balance
                if amount > 0.0 {
                    // Calculate fee: amount * depositFeeBps / 10000
                    let fee = amount * UFix64(self.depositFeeBps) / 10000.0
                    let netAmount = amount - fee

                    // Withdraw full amount from source
                    let fullVault <- from.withdraw(amount: amount)

                    if fee > 0.0 {
                        // Split: withdraw fee portion from the full vault
                        let feeVault <- fullVault.withdraw(amount: fee)

                        // Deposit fee into fee sink
                        if let feeSink = self.feeSinkCap.borrow() {
                            feeSink.deposit(from: <-feeVault)
                        } else {
                            // If fee sink is unavailable, destroy the fee tokens
                            destroy feeVault
                        }
                    }

                    // Deposit remainder (net amount) into underlying vault
                    receiver.deposit(from: <-fullVault)
                }
            }
        }

        // ============ Source Interface ============

        /// Returns the Vault type provided by this Source
        access(all) view fun getSourceType(): Type {
            return self.vaultType
        }

        /// Returns the available balance that can be withdrawn (truthful reporting)
        access(all) fun minimumAvailable(): UFix64 {
            if let provider = self.providerCap.borrow() {
                return provider.balance
            }
            return 0.0
        }

        /// Withdraws up to maxAmount from the underlying vault (no withdrawal fee)
        access(FungibleToken.Withdraw) fun withdrawAvailable(maxAmount: UFix64): @{FungibleToken.Vault} {
            if let provider = self.providerCap.borrow() {
                let available = provider.balance
                let withdrawAmount = maxAmount < available ? maxAmount : available
                if withdrawAmount > 0.0 {
                    return <-provider.withdraw(amount: withdrawAmount)
                }
            }
            // Return an empty vault if we can't withdraw
            return <-DeFiActionsUtils.getEmptyVault(self.vaultType)
        }

        // ============ IdentifiableStruct Interface ============

        /// Returns component info for DeFiActions tracing
        access(all) fun getComponentInfo(): DeFiActions.ComponentInfo {
            return DeFiActions.ComponentInfo(
                type: self.getType(),
                id: self.id(),
                innerComponents: []
            )
        }
        /// Returns a copy of the UniqueIdentifier
        access(contract) view fun copyID(): DeFiActions.UniqueIdentifier? {
            return self.uniqueID
        }
        /// Sets the UniqueIdentifier
        access(contract) fun setID(_ id: DeFiActions.UniqueIdentifier?) {
            self.uniqueID = id
        }
    }

    /// Creates a new SlippageVaultConnector with a configurable deposit fee
    access(all) fun createSlippageVaultConnector(
        providerCap: Capability<auth(FungibleToken.Withdraw) &{FungibleToken.Provider, FungibleToken.Balance}>,
        receiverCap: Capability<&{FungibleToken.Receiver}>,
        feeSinkCap: Capability<&{FungibleToken.Receiver}>,
        vaultType: Type,
        depositFeeBps: UInt64
    ): SlippageVaultConnector {
        return SlippageVaultConnector(
            providerCap: providerCap,
            receiverCap: receiverCap,
            feeSinkCap: feeSinkCap,
            vaultType: vaultType,
            depositFeeBps: depositFeeBps
        )
    }

    /// TruncatingVaultConnector - A connector that truncates withdrawal amounts to 6 decimal places
    /// Simulates EVM bridge behavior where assets only have 6 decimals of precision,
    /// causing the last 2 digits of UFix64's 8-decimal precision to be lost on withdrawal.
    access(all) struct TruncatingVaultConnector: DeFiActions.Sink, DeFiActions.Source {
        /// Capability to withdraw from the underlying vault
        access(self) let providerCap: Capability<auth(FungibleToken.Withdraw) &{FungibleToken.Provider, FungibleToken.Balance}>
        /// Capability to deposit to the underlying vault
        access(self) let receiverCap: Capability<&{FungibleToken.Receiver}>
        /// The vault type this connector handles
        access(self) let vaultType: Type
        /// UniqueIdentifier for DeFiActions tracing
        access(contract) var uniqueID: DeFiActions.UniqueIdentifier?

        init(
            providerCap: Capability<auth(FungibleToken.Withdraw) &{FungibleToken.Provider, FungibleToken.Balance}>,
            receiverCap: Capability<&{FungibleToken.Receiver}>,
            vaultType: Type
        ) {
            self.providerCap = providerCap
            self.receiverCap = receiverCap
            self.vaultType = vaultType
            self.uniqueID = nil
        }

        /// Truncates a UFix64 value to 6 decimal places (same logic as FlowYieldVaultsConnectorV2)
        access(all) view fun truncateToSixDecimals(_ value: UFix64): UFix64 {
            if value == 0.0 { return 0.0 }

            let PRECISION_FACTOR: UFix64 = 1000000.0  // 10^6 for 6 decimals

            // Split into integer + fractional to avoid overflow
            let integerPart: UFix64 = UFix64(UInt64(value))
            let fractionalPart: UFix64 = value - integerPart

            let scaledFrac: UFix64 = fractionalPart * PRECISION_FACTOR
            let truncatedFrac: UInt64 = UInt64(scaledFrac)  // Floor (truncate toward zero)

            return integerPart + UFix64(truncatedFrac) / PRECISION_FACTOR
        }

        // ============ Sink Interface ============

        access(all) view fun getSinkType(): Type {
            return self.vaultType
        }

        access(all) fun minimumCapacity(): UFix64 {
            return UFix64.max
        }

        access(all) fun depositCapacity(from: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}) {
            if let receiver = self.receiverCap.borrow() {
                let amount = from.balance
                if amount > 0.0 {
                    receiver.deposit(from: <-from.withdraw(amount: amount))
                }
            }
        }

        // ============ Source Interface ============

        access(all) view fun getSourceType(): Type {
            return self.vaultType
        }

        /// Reports balance truncated to 6 decimals (simulates EVM bridge precision loss)
        access(all) fun minimumAvailable(): UFix64 {
            if let provider = self.providerCap.borrow() {
                return self.truncateToSixDecimals(provider.balance)
            }
            return 0.0
        }

        /// Withdraws up to maxAmount, but truncates the actual withdrawal to 6 decimals
        access(FungibleToken.Withdraw) fun withdrawAvailable(maxAmount: UFix64): @{FungibleToken.Vault} {
            if let provider = self.providerCap.borrow() {
                let available = provider.balance
                let requestedAmount = maxAmount < available ? maxAmount : available
                // Truncate to 6 decimals before withdrawing
                let truncatedAmount = self.truncateToSixDecimals(requestedAmount)
                if truncatedAmount > 0.0 {
                    return <-provider.withdraw(amount: truncatedAmount)
                }
            }
            return <-DeFiActionsUtils.getEmptyVault(self.vaultType)
        }

        // ============ IdentifiableStruct Interface ============

        access(all) fun getComponentInfo(): DeFiActions.ComponentInfo {
            return DeFiActions.ComponentInfo(
                type: self.getType(),
                id: self.id(),
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

    /// Creates a new TruncatingVaultConnector
    access(all) fun createTruncatingVaultConnector(
        providerCap: Capability<auth(FungibleToken.Withdraw) &{FungibleToken.Provider, FungibleToken.Balance}>,
        receiverCap: Capability<&{FungibleToken.Receiver}>,
        vaultType: Type
    ): TruncatingVaultConnector {
        return TruncatingVaultConnector(
            providerCap: providerCap,
            receiverCap: receiverCap,
            vaultType: vaultType
        )
    }
}

