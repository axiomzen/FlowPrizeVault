import "FungibleToken"
import "DeFiActions"
import "DeFiActionsUtils"

/// MockYieldConnector - Simple vault connector for testing PrizeSavings
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
}

