/*
FlowVaultsConnectorTestnet - Testnet-Compatible Flow Vaults Integration

This version implements DeFiActions.Sink and DeFiActions.Source (struct interfaces)
to work with PrizeSavings on testnet, while managing Flow Vaults integration.

Flow Vaults Contract: testnet://3bda2f90274dbc9b.FlowVaults
DeFiActions on testnet uses STRUCT interfaces (not resource interfaces)
*/

import "FungibleToken"
import "FlowVaults"
import "FlowVaultsClosedBeta"
import "DeFiActions"

access(all) contract FlowVaultsConnectorTestnet {
    
    // Storage paths
    access(all) let ManagerStoragePath: StoragePath
    access(all) let ManagerPublicPath: PublicPath
    
    // Events
    access(all) event ConnectorCreated(managerAddress: Address, strategyType: String, vaultType: String)
    access(all) event DepositedToTide(tideID: UInt64, amount: UFix64, vaultType: String)
    access(all) event WithdrawnFromTide(tideID: UInt64, amount: UFix64, vaultType: String)
    access(all) event TideCreated(tideID: UInt64, strategyType: String, initialAmount: UFix64)
    
    /// TideManagerWrapper Resource
    /// Wraps FlowVaults.TideManager with beta badge authentication
    /// This must be a resource because it holds capabilities
    access(all) resource TideManagerWrapper {
        access(self) let tideManagerCap: Capability<auth(FungibleToken.Withdraw) &FlowVaults.TideManager>
        access(self) let betaBadgeCap: Capability<auth(FlowVaultsClosedBeta.Beta) &FlowVaultsClosedBeta.BetaBadge>
        access(self) var tideID: UInt64?
        access(all) let vaultType: Type
        access(all) let strategyType: Type
        
        init(
            tideManagerCap: Capability<auth(FungibleToken.Withdraw) &FlowVaults.TideManager>,
            betaBadgeCap: Capability<auth(FlowVaultsClosedBeta.Beta) &FlowVaultsClosedBeta.BetaBadge>,
            vaultType: Type,
            strategyType: Type
        ) {
            pre {
                tideManagerCap.check(): "Invalid TideManager capability"
                betaBadgeCap.check(): "Invalid Beta badge capability"
            }
            
            self.tideManagerCap = tideManagerCap
            self.betaBadgeCap = betaBadgeCap
            self.vaultType = vaultType
            self.strategyType = strategyType
            self.tideID = nil
        }
        
        access(all) fun depositToTide(from: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}) {
            pre {
                from.getType() == self.vaultType: "Vault type mismatch"
                from.balance > 0.0: "Cannot deposit zero balance"
            }
            
            let amount = from.balance
            let tideManager = self.tideManagerCap.borrow()
                ?? panic("Cannot borrow TideManager")
            let betaBadge = self.betaBadgeCap.borrow()
                ?? panic("Cannot borrow Beta badge")
            
            // If we don't have a Tide yet, create one
            if self.tideID == nil {
                let initialVault <- from.withdraw(amount: amount)
                
                tideManager.createTide(
                    betaRef: betaBadge,
                    strategyType: self.strategyType,
                    withVault: <- initialVault
                )
                
                let tideIDs = tideManager.getIDs()
                assert(tideIDs.length > 0, message: "Failed to create Tide")
                self.tideID = tideIDs[tideIDs.length - 1]
                
                emit TideCreated(
                    tideID: self.tideID!,
                    strategyType: self.strategyType.identifier,
                    initialAmount: amount
                )
                
                emit DepositedToTide(
                    tideID: self.tideID!,
                    amount: amount,
                    vaultType: self.vaultType.identifier
                )
            } else {
                let depositVault <- from.withdraw(amount: amount)
                
                tideManager.depositToTide(
                    betaRef: betaBadge,
                    self.tideID!,
                    from: <- depositVault
                )
                
                emit DepositedToTide(
                    tideID: self.tideID!,
                    amount: amount,
                    vaultType: self.vaultType.identifier
                )
            }
        }
        
        access(all) fun getTideBalance(): UFix64 {
            if self.tideID == nil {
                return 0.0
            }
            
            let tideManager = self.tideManagerCap.borrow()
                ?? panic("Cannot borrow TideManager")
            
            let tideRef = tideManager.borrowTide(id: self.tideID!)
            if tideRef == nil {
                return 0.0
            }
            
            return tideRef!.getTideBalance()
        }
        
        access(all) fun withdrawFromTide(maxAmount: UFix64): @{FungibleToken.Vault} {
            pre {
                self.tideID != nil: "No Tide initialized"
                maxAmount > 0.0: "Cannot withdraw zero amount"
            }
            
            let tideManager = self.tideManagerCap.borrow()
                ?? panic("Cannot borrow TideManager")
            
            let available = self.getTideBalance()
            let withdrawAmount = maxAmount < available ? maxAmount : available
            
            assert(withdrawAmount > 0.0, message: "Insufficient balance in Tide")
            
            let vault <- tideManager.withdrawFromTide(self.tideID!, amount: withdrawAmount)
            
            emit WithdrawnFromTide(
                tideID: self.tideID!,
                amount: withdrawAmount,
                vaultType: vault.getType().identifier
            )
            
            return <- vault
        }
    }
    
    /// Connector Struct
    /// Implements DeFiActions.Sink and DeFiActions.Source (testnet uses struct interfaces)
    /// References a stored TideManagerWrapper resource
    access(all) struct Connector: DeFiActions.Sink, DeFiActions.Source {
        access(all) let managerAddress: Address
        access(contract) var uniqueID: DeFiActions.UniqueIdentifier?
        access(all) let vaultType: Type
        
        init(managerAddress: Address, vaultType: Type) {
            self.managerAddress = managerAddress
            self.vaultType = vaultType
            self.uniqueID = nil
        }
        
        /// DeFiActions.Sink Implementation
        access(all) fun depositCapacity(from: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}) {
            let managerAccount = getAccount(self.managerAddress)
            let managerRef = managerAccount.capabilities.borrow<&TideManagerWrapper>(
                FlowVaultsConnectorTestnet.ManagerPublicPath
            ) ?? panic("Cannot borrow TideManagerWrapper from address")
            
            managerRef.depositToTide(from: from)
        }
        
        access(all) view fun getSinkType(): Type {
            return self.vaultType
        }
        
        access(all) view fun minimumCapacity(): UFix64 {
            return 0.0
        }
        
        /// DeFiActions.Source Implementation
        access(all) fun minimumAvailable(): UFix64 {
            // Returns the actual Tide balance by borrowing the TideManagerWrapper
            // Note: minimumAvailable() is NOT required to be a view function per DeFiActions.Source interface
            let managerAccount = getAccount(self.managerAddress)
            if let managerRef = managerAccount.capabilities.borrow<&TideManagerWrapper>(
                FlowVaultsConnectorTestnet.ManagerPublicPath
            ) {
                return managerRef.getTideBalance()
            }
            return 0.0
        }
        
        access(FungibleToken.Withdraw) fun withdrawAvailable(maxAmount: UFix64): @{FungibleToken.Vault} {
            let managerAccount = getAccount(self.managerAddress)
            let managerRef = managerAccount.capabilities.borrow<&TideManagerWrapper>(
                FlowVaultsConnectorTestnet.ManagerPublicPath
            ) ?? panic("Cannot borrow TideManagerWrapper from address")
            
            return <- managerRef.withdrawFromTide(maxAmount: maxAmount)
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
    
    /// Create a new TideManagerWrapper and store it
    /// Returns a Connector struct that references it
    access(all) fun createConnectorAndManager(
        account: auth(Storage, Capabilities) &Account,
        tideManagerCap: Capability<auth(FungibleToken.Withdraw) &FlowVaults.TideManager>,
        betaBadgeCap: Capability<auth(FlowVaultsClosedBeta.Beta) &FlowVaultsClosedBeta.BetaBadge>,
        vaultType: Type,
        strategyType: Type
    ): Connector {
        // Validate that the strategy supports the vault type
        let supportedVaults = FlowVaults.getSupportedInitializationVaults(forStrategy: strategyType)
        assert(
            supportedVaults[vaultType] == true,
            message: "Strategy does not support vault type"
        )
        
        // Create and store the TideManagerWrapper resource
        let manager <- create TideManagerWrapper(
            tideManagerCap: tideManagerCap,
            betaBadgeCap: betaBadgeCap,
            vaultType: vaultType,
            strategyType: strategyType
        )
        
        account.storage.save(<-manager, to: self.ManagerStoragePath)
        
        // Create public capability for the manager
        let managerCap = account.capabilities.storage.issue<&TideManagerWrapper>(self.ManagerStoragePath)
        account.capabilities.publish(managerCap, at: self.ManagerPublicPath)
        
        emit ConnectorCreated(
            managerAddress: account.address,
            strategyType: strategyType.identifier,
            vaultType: vaultType.identifier
        )
        
        // Return the struct connector that references this manager
        return Connector(
            managerAddress: account.address,
            vaultType: vaultType
        )
    }
    
    init() {
        self.ManagerStoragePath = /storage/flowVaultsTideManager
        self.ManagerPublicPath = /public/flowVaultsTideManager
    }
}
