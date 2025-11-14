import "FungibleToken"
import "DeFiActions"

/// Test helper contract for emulator testing
/// Provides simple mock implementations of DeFiActions interfaces
access(all) contract TestHelpers {
    
    /// Simple vault-based sink for testing
    access(all) struct SimpleVaultSink: DeFiActions.Sink {
        access(all) let receiverCap: Capability<&{FungibleToken.Receiver}>
        access(all) let vaultType: Type
        access(contract) var uniqueID: DeFiActions.UniqueIdentifier?
        
        init(receiverCap: Capability<&{FungibleToken.Receiver}>, vaultType: Type) {
            self.receiverCap = receiverCap
            self.vaultType = vaultType
            self.uniqueID = nil
        }
        
        access(all) fun depositCapacity(from: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}) {
            let receiver = self.receiverCap.borrow() ?? panic("Cannot borrow receiver")
            let amount = from.balance
            receiver.deposit(from: <- from.withdraw(amount: amount))
        }
        
        access(all) view fun getSinkType(): Type {
            return self.vaultType
        }
        
        access(all) view fun minimumCapacity(): UFix64 {
            return 0.0  // No minimum capacity for testing
        }
        
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
    
    /// Simple vault-based source for testing
    access(all) struct SimpleVaultSource: DeFiActions.Source {
        access(all) let providerCap: Capability<auth(FungibleToken.Withdraw) &{FungibleToken.Provider, FungibleToken.Balance}>
        access(all) let vaultType: Type
        access(contract) var uniqueID: DeFiActions.UniqueIdentifier?
        
        init(providerCap: Capability<auth(FungibleToken.Withdraw) &{FungibleToken.Provider, FungibleToken.Balance}>, vaultType: Type) {
            self.providerCap = providerCap
            self.vaultType = vaultType
            self.uniqueID = nil
        }
        
        access(all) view fun minimumAvailable(): UFix64 {
            if let provider = self.providerCap.borrow() {
                return provider.balance
            }
            return 0.0
        }
        
        access(FungibleToken.Withdraw) fun withdrawAvailable(maxAmount: UFix64): @{FungibleToken.Vault} {
            let provider = self.providerCap.borrow() ?? panic("Cannot borrow provider")
            let available = provider.balance
            let toWithdraw = maxAmount < available ? maxAmount : available
            return <- provider.withdraw(amount: toWithdraw)
        }
        
        access(all) view fun getSourceType(): Type {
            return self.vaultType
        }
        
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
    
    /// Combined Sink + Source connector for testing
    /// Implements both interfaces for a single vault
    access(all) struct SimpleVaultConnector: DeFiActions.Sink, DeFiActions.Source {
        access(all) let providerCap: Capability<auth(FungibleToken.Withdraw) &{FungibleToken.Provider, FungibleToken.Balance}>
        access(all) let receiverCap: Capability<&{FungibleToken.Receiver}>
        access(all) let vaultType: Type
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
        
        // Sink interface implementation
        access(all) fun depositCapacity(from: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}) {
            let receiver = self.receiverCap.borrow() ?? panic("Cannot borrow receiver")
            let amount = from.balance
            receiver.deposit(from: <- from.withdraw(amount: amount))
        }
        
        access(all) view fun getSinkType(): Type {
            return self.vaultType
        }
        
        access(all) view fun minimumCapacity(): UFix64 {
            return 0.0  // No minimum capacity for testing
        }
        
        // Source interface implementation
        access(all) view fun minimumAvailable(): UFix64 {
            if let provider = self.providerCap.borrow() {
                return provider.balance
            }
            return 0.0
        }
        
        access(FungibleToken.Withdraw) fun withdrawAvailable(maxAmount: UFix64): @{FungibleToken.Vault} {
            let provider = self.providerCap.borrow() ?? panic("Cannot borrow provider")
            let available = provider.balance
            let toWithdraw = maxAmount < available ? maxAmount : available
            return <- provider.withdraw(amount: toWithdraw)
        }
        
        access(all) view fun getSourceType(): Type {
            return self.vaultType
        }
        
        // Shared interface implementations
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
}
