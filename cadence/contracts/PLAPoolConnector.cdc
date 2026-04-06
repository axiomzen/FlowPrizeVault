import "FungibleToken"
import "DeFiActions"
import "DeFiActionsUtils"
import "PrizeLinkedAccounts"

/// PLAPoolConnector
///
/// Bridges DeFiActions Sink/Source interfaces to PrizeLinkedAccounts' PoolPositionCollection.
/// Used by PLAStrategy (FlowYieldVaults) to route borrowed tokens into a PLA Pool.
///
/// The Connector struct holds an entitled capability to a PoolPositionCollection and a poolID.
/// Token type is resolved dynamically from the pool's config.assetType — not hardcoded.
///
access(all) contract PLAPoolConnector {

    // Events
    access(all) event ConnectorCreated(poolID: UInt64, vaultType: String)

    /// Connector - Implements DeFiActions.Sink and DeFiActions.Source
    /// by delegating to a PoolPositionCollection's deposit/withdraw methods.
    ///
    /// Follows the FlowYieldVaultsConnectorV2.Connector convention:
    /// single struct implementing both interfaces, holding an entitled capability.
    ///
    access(all) struct Connector: DeFiActions.Sink, DeFiActions.Source {
        /// Entitled capability for deposit/withdraw operations
        access(self) let collectionCap: Capability<auth(PrizeLinkedAccounts.PositionOps) &PrizeLinkedAccounts.PoolPositionCollection>
        /// Target PLA pool ID
        access(all) let poolID: UInt64
        /// Pool's accepted token type (resolved from Pool.getConfig().assetType)
        access(all) let vaultType: Type
        /// UniqueIdentifier for DeFiActions tracing
        access(contract) var uniqueID: DeFiActions.UniqueIdentifier?

        init(
            collectionCap: Capability<auth(PrizeLinkedAccounts.PositionOps) &PrizeLinkedAccounts.PoolPositionCollection>,
            poolID: UInt64,
            vaultType: Type
        ) {
            pre {
                collectionCap.check(): "PLAPoolConnector.Connector.init: invalid collectionCap"
            }
            self.collectionCap = collectionCap
            self.poolID = poolID
            self.vaultType = vaultType
            self.uniqueID = nil
        }

        // ============ Sink Interface ============

        /// Returns the Vault type accepted by this Sink
        access(all) view fun getSinkType(): Type {
            return self.vaultType
        }

        /// Returns minimum deposit capacity (no minimum for PLA pools)
        access(all) fun minimumCapacity(): UFix64 {
            return 0.0
        }

        /// Deposits funds into the PLA Pool via the PoolPositionCollection.
        /// Withdraws from the authorized vault ref to create an owned vault,
        /// then delegates to collection.deposit().
        /// Uses maxSlippageBps: 10000 (no slippage protection) since deposits
        /// are same-denomination — no swap involved.
        access(all) fun depositCapacity(from: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}) {
            let collectionRef = self.collectionCap.borrow()
                ?? panic("PLAPoolConnector.Connector.depositCapacity: failed to borrow PoolPositionCollection")

            let amount = from.balance
            if amount > 0.0 {
                collectionRef.deposit(
                    poolID: self.poolID,
                    from: <- from.withdraw(amount: amount),
                    maxSlippageBps: 10000
                )
            }
        }

        // ============ Source Interface ============

        /// Returns the Vault type provided by this Source
        access(all) view fun getSourceType(): Type {
            return self.vaultType
        }

        /// Returns the available balance that can be withdrawn from the PLA Pool.
        access(all) fun minimumAvailable(): UFix64 {
            if let collectionRef = self.collectionCap.borrow() {
                let balance = collectionRef.getPoolBalance(poolID: self.poolID)
                return balance.totalBalance
            }
            return 0.0
        }

        /// Withdraws up to maxAmount from the PLA Pool.
        /// May return an empty vault if the pool's yield source has liquidity issues.
        access(FungibleToken.Withdraw) fun withdrawAvailable(maxAmount: UFix64): @{FungibleToken.Vault} {
            let collectionRef = self.collectionCap.borrow()
                ?? panic("PLAPoolConnector.Connector.withdrawAvailable: failed to borrow PoolPositionCollection")

            if maxAmount == 0.0 {
                return <- DeFiActionsUtils.getEmptyVault(self.vaultType)
            }

            let available = collectionRef.getPoolBalance(poolID: self.poolID).totalBalance
            if available == 0.0 {
                return <- DeFiActionsUtils.getEmptyVault(self.vaultType)
            }

            let withdrawAmount = maxAmount < available ? maxAmount : available
            return <- collectionRef.withdraw(poolID: self.poolID, amount: withdrawAmount)
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

    /// Creates a new Connector for the given pool.
    /// Resolves the accepted token type from the pool's config.
    ///
    /// @param collectionCap - Entitled capability to a PoolPositionCollection
    /// @param poolID - Target PLA pool ID
    /// @return Configured Connector struct
    ///
    access(all) fun createConnector(
        collectionCap: Capability<auth(PrizeLinkedAccounts.PositionOps) &PrizeLinkedAccounts.PoolPositionCollection>,
        poolID: UInt64
    ): Connector {
        pre {
            collectionCap.check(): "PLAPoolConnector.createConnector: invalid collectionCap"
        }

        let poolRef = PrizeLinkedAccounts.borrowPool(poolID: poolID)
            ?? panic("PLAPoolConnector.createConnector: Pool with ID ".concat(poolID.toString()).concat(" does not exist"))

        let vaultType = poolRef.getConfig().assetType

        emit ConnectorCreated(poolID: poolID, vaultType: vaultType.identifier)

        return Connector(
            collectionCap: collectionCap,
            poolID: poolID,
            vaultType: vaultType
        )
    }

    init() {}
}
