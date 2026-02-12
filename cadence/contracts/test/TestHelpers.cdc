import "FungibleToken"
import "DeFiActions"

/// TestHelpers - Production-Safe Vault Connector for Testing
/// 
/// This contract provides secure mock implementations of DeFiActions interfaces
/// for testing purposes. It follows the same security pattern as FlowYieldVaultsConnector.
///
/// SECURITY MODEL:
/// - Vault capabilities are stored in a Resource (VaultManager), NOT in structs
/// - Resources cannot be copied, protecting the underlying vault capabilities
/// - The Connector struct only holds a capability to the VaultManager resource
/// - Only the VaultManager owner (account) can create Connectors
/// - Public interface only exposes safe operations (deposit, balance check)
/// - Withdraw operations require entitled capability that can be revoked
/// - All operations emit events for transparency and monitoring
///
/// USAGE:
/// 1. Call createVaultManagerAndConnector() with your account to set up the manager
/// 2. Use the returned VaultConnector with PrizeSavings
/// 3. Fund the manager's underlying vault for testing
///
/// NOTE: While this is production-safe, it should primarily be used for testing.
/// For production yield sources, use proper DeFi integrations like FlowYieldVaultsConnector.
///
access(all) contract TestHelpers {
    
    // Entitlement for withdraw operations - only entitled references can withdraw
    access(all) entitlement Withdraw
    
    // Storage paths
    access(all) let VaultManagerStoragePath: StoragePath
    access(all) let VaultManagerPublicPath: PublicPath
    
    // Events for transparency and monitoring
    access(all) event VaultManagerCreated(ownerAddress: Address, vaultType: String)
    access(all) event ConnectorCreated(managerAddress: Address, vaultType: String)
    access(all) event DepositedToManager(managerAddress: Address, amount: UFix64, vaultType: String)
    access(all) event WithdrawnFromManager(managerAddress: Address, amount: UFix64, vaultType: String)
    
    /// Public interface - exposes only safe operations
    /// Anyone can deposit funds and check balance, but cannot withdraw
    access(all) resource interface VaultManagerPublic {
        access(all) view fun getBalance(): UFix64
        access(all) view fun getVaultType(): Type
        access(all) fun deposit(from: @{FungibleToken.Vault})
    }
    
    /// VaultManager Resource
    /// 
    /// SECURITY: This resource holds the sensitive vault capabilities.
    /// Resources cannot be copied, so the capabilities are protected.
    /// Only entitled references can call withdrawFunds.
    ///
    access(all) resource VaultManager: VaultManagerPublic {
        /// Private: Vault provider capability - can withdraw funds
        access(self) let providerCap: Capability<auth(FungibleToken.Withdraw) &{FungibleToken.Provider, FungibleToken.Balance}>
        
        /// Private: Vault receiver capability - can receive deposits
        access(self) let receiverCap: Capability<&{FungibleToken.Receiver}>
        
        /// Public: Vault type for type checking
        access(all) let vaultType: Type
        
        /// Public: Owner address for monitoring
        access(all) let ownerAddress: Address
        
        init(
            providerCap: Capability<auth(FungibleToken.Withdraw) &{FungibleToken.Provider, FungibleToken.Balance}>,
            receiverCap: Capability<&{FungibleToken.Receiver}>,
            vaultType: Type,
            ownerAddress: Address
        ) {
            pre {
                providerCap.check(): "Invalid provider capability"
                receiverCap.check(): "Invalid receiver capability"
            }
            self.providerCap = providerCap
            self.receiverCap = receiverCap
            self.vaultType = vaultType
            self.ownerAddress = ownerAddress
        }
        
        /// Get current balance - SAFE: read-only operation
        access(all) view fun getBalance(): UFix64 {
            if let provider = self.providerCap.borrow() {
                return provider.balance
            }
            return 0.0
        }
        
        /// Get vault type - SAFE: read-only operation
        access(all) view fun getVaultType(): Type {
            return self.vaultType
        }
        
        /// Deposit funds - SAFE: adding funds doesn't risk existing funds
        access(all) fun deposit(from: @{FungibleToken.Vault}) {
            pre {
                from.getType() == self.vaultType: "Vault type mismatch: expected ".concat(self.vaultType.identifier)
            }
            let amount = from.balance
            let receiver = self.receiverCap.borrow() ?? panic("Cannot borrow receiver capability")
            receiver.deposit(from: <- from)
            emit DepositedToManager(
                managerAddress: self.ownerAddress,
                amount: amount,
                vaultType: self.vaultType.identifier
            )
        }
        
        /// Withdraw funds - PROTECTED: requires Withdraw entitlement
        /// Only callable through an entitled reference, which can only be issued
        /// by the account that stores this resource.
        access(Withdraw) fun withdrawFunds(maxAmount: UFix64): @{FungibleToken.Vault} {
            let provider = self.providerCap.borrow() 
                ?? panic("Cannot borrow provider capability")
            let available = provider.balance
            let toWithdraw = maxAmount < available ? maxAmount : available
            
            if toWithdraw == 0.0 {
                // Return empty vault of correct type
                return <- provider.withdraw(amount: 0.0)
            }
            
            let vault <- provider.withdraw(amount: toWithdraw)
            emit WithdrawnFromManager(
                managerAddress: self.ownerAddress,
                amount: toWithdraw,
                vaultType: self.vaultType.identifier
            )
            return <- vault
        }
    }
    
    /// VaultConnector Struct
    /// 
    /// Implements DeFiActions.Sink and DeFiActions.Source for use with PrizeSavings.
    /// 
    /// SECURITY:
    /// - Only holds a capability to VaultManager, NOT the raw vault capability
    /// - Deposit uses public capability (safe - anyone can deposit)
    /// - Withdraw uses entitled capability (protected - requires Withdraw entitlement)
    /// - The entitled capability can only be issued by the VaultManager owner
    ///
    access(all) struct VaultConnector: DeFiActions.Sink, DeFiActions.Source {
        /// Address of the account that owns the VaultManager resource
        access(all) let managerAddress: Address
        
        /// Entitled capability to VaultManager for withdraw operations
        /// This can only be issued by the account that stores the VaultManager
        access(self) let withdrawCap: Capability<auth(Withdraw) &VaultManager>
        
        /// Vault type for interface compliance
        access(all) let vaultType: Type
        
        /// DeFiActions unique ID
        access(contract) var uniqueID: DeFiActions.UniqueIdentifier?
        
        init(
            managerAddress: Address,
            withdrawCap: Capability<auth(Withdraw) &VaultManager>,
            vaultType: Type
        ) {
            pre {
                withdrawCap.check(): "Invalid withdraw capability"
            }
            self.managerAddress = managerAddress
            self.withdrawCap = withdrawCap
            self.vaultType = vaultType
            self.uniqueID = nil
        }
        
        // ============================================================
        // DeFiActions.Sink Implementation
        // ============================================================
        
        /// Deposit funds into the managed vault
        /// Uses PUBLIC capability - safe operation
        access(all) fun depositCapacity(from: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}) {
            let managerAccount = getAccount(self.managerAddress)
            let managerRef = managerAccount.capabilities.borrow<&{VaultManagerPublic}>(
                TestHelpers.VaultManagerPublicPath
            ) ?? panic("Cannot borrow VaultManager from ".concat(self.managerAddress.toString()))
            
            let amount = from.balance
            managerRef.deposit(from: <- from.withdraw(amount: amount))
        }
        
        access(all) view fun getSinkType(): Type {
            return self.vaultType
        }
        
        access(all) view fun minimumCapacity(): UFix64 {
            return 0.0
        }
        
        // ============================================================
        // DeFiActions.Source Implementation
        // ============================================================
        
        /// Get available balance
        /// Uses PUBLIC capability - safe read-only operation
        access(all) view fun minimumAvailable(): UFix64 {
            let managerAccount = getAccount(self.managerAddress)
            if let managerRef = managerAccount.capabilities.borrow<&{VaultManagerPublic}>(
                TestHelpers.VaultManagerPublicPath
            ) {
                return managerRef.getBalance()
            }
            return 0.0
        }
        
        /// Withdraw funds from the managed vault
        /// Uses ENTITLED capability - protected operation
        access(FungibleToken.Withdraw) fun withdrawAvailable(maxAmount: UFix64): @{FungibleToken.Vault} {
            let managerRef = self.withdrawCap.borrow() 
                ?? panic("Cannot borrow VaultManager with Withdraw entitlement. Capability may have been revoked.")
            return <- managerRef.withdrawFunds(maxAmount: maxAmount)
        }
        
        access(all) view fun getSourceType(): Type {
            return self.vaultType
        }
        
        // ============================================================
        // DeFiActions Component Interface
        // ============================================================
        
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
    
    // ============================================================
    // Factory Functions
    // ============================================================
    
    /// Create a VaultManager resource and store it in the caller's account.
    /// Returns a VaultConnector that can be used with PrizeSavings.
    ///
    /// SECURITY: This function requires auth(Storage, Capabilities) which means
    /// only the account owner can call it through a transaction they sign.
    ///
    /// @param account: The account to store the VaultManager in (must be signer)
    /// @param providerCap: Capability to withdraw from the vault (will be protected)
    /// @param receiverCap: Capability to deposit into the vault
    /// @param vaultType: Type of the fungible token vault
    /// @return VaultConnector struct for use with PrizeSavings
    ///
    access(all) fun createVaultManagerAndConnector(
        account: auth(Storage, Capabilities) &Account,
        providerCap: Capability<auth(FungibleToken.Withdraw) &{FungibleToken.Provider, FungibleToken.Balance}>,
        receiverCap: Capability<&{FungibleToken.Receiver}>,
        vaultType: Type
    ): VaultConnector {
        pre {
            providerCap.check(): "Invalid provider capability"
            receiverCap.check(): "Invalid receiver capability"
            account.storage.borrow<&VaultManager>(from: self.VaultManagerStoragePath) == nil: 
                "VaultManager already exists at this storage path"
        }
        
        // Create and store the VaultManager resource
        let manager <- create VaultManager(
            providerCap: providerCap,
            receiverCap: receiverCap,
            vaultType: vaultType,
            ownerAddress: account.address
        )
        
        account.storage.save(<-manager, to: self.VaultManagerStoragePath)
        
        // Issue and publish PUBLIC capability (deposit and balance only)
        let publicCap = account.capabilities.storage.issue<&{VaultManagerPublic}>(
            self.VaultManagerStoragePath
        )
        account.capabilities.publish(publicCap, at: self.VaultManagerPublicPath)
        
        // Issue ENTITLED capability for withdrawals (NOT published publicly)
        // This capability is stored in the returned connector
        let withdrawCap = account.capabilities.storage.issue<auth(Withdraw) &VaultManager>(
            self.VaultManagerStoragePath
        )
        
        emit VaultManagerCreated(
            ownerAddress: account.address, 
            vaultType: vaultType.identifier
        )
        emit ConnectorCreated(
            managerAddress: account.address, 
            vaultType: vaultType.identifier
        )
        
        return VaultConnector(
            managerAddress: account.address,
            withdrawCap: withdrawCap,
            vaultType: vaultType
        )
    }
    
    /// Create an additional connector for an existing VaultManager.
    /// Useful if you need to use the same vault for multiple pools.
    ///
    /// SECURITY: Requires auth(Capabilities) - only account owner can create connectors
    ///
    access(all) fun createAdditionalConnector(
        account: auth(Capabilities) &Account
    ): VaultConnector {
        // Verify the account has a VaultManager by borrowing public capability
        let publicCap = account.capabilities.get<&{VaultManagerPublic}>(self.VaultManagerPublicPath)
        let managerRef = publicCap.borrow() 
            ?? panic("No VaultManager found. Call createVaultManagerAndConnector first.")
        
        let vaultType = managerRef.getVaultType()
        
        // Issue a new entitled capability for this connector
        let withdrawCap = account.capabilities.storage.issue<auth(Withdraw) &VaultManager>(
            self.VaultManagerStoragePath
        )
        
        emit ConnectorCreated(
            managerAddress: account.address, 
            vaultType: vaultType.identifier
        )
        
        return VaultConnector(
            managerAddress: account.address,
            withdrawCap: withdrawCap,
            vaultType: vaultType
        )
    }
    
    // ============================================================
    // Contract Initialization
    // ============================================================
    
    init() {
        // Use contract address in path identifier for uniqueness
        let identifier = "testHelpersVaultManager_".concat(self.account.address.toString())
        self.VaultManagerStoragePath = StoragePath(identifier: identifier)!
        self.VaultManagerPublicPath = PublicPath(identifier: identifier)!
    }
}
