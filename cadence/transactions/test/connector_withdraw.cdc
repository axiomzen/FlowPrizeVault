import "FungibleToken"
import "FlowToken"
import "DeFiActions"
import "PrizeLinkedAccounts"
import "PLAPoolConnector"

/// Test transaction: withdraws via PLAPoolConnector.Connector's Source interface.
/// Simulates what PLAStrategy would do when pulling tokens back from PLA.
///
transaction(poolID: UInt64, amount: UFix64) {
    let connector: PLAPoolConnector.Connector
    let receiverRef: &{FungibleToken.Receiver}

    prepare(signer: auth(Storage, Capabilities) &Account) {
        // Issue capability for the PoolPositionCollection
        let collectionCap = signer.capabilities.storage.issue<
            auth(PrizeLinkedAccounts.PositionOps) &PrizeLinkedAccounts.PoolPositionCollection
        >(PrizeLinkedAccounts.PoolPositionCollectionStoragePath)

        // Create connector
        self.connector = PLAPoolConnector.createConnector(
            collectionCap: collectionCap,
            poolID: poolID
        )

        // Borrow receiver to deposit withdrawn tokens back
        self.receiverRef = signer.storage.borrow<&FlowToken.Vault>(
            from: /storage/flowTokenVault
        ) ?? panic("Could not borrow FlowToken receiver")
    }

    execute {
        // Withdraw via the Source interface
        let withdrawn <- self.connector.withdrawAvailable(maxAmount: amount)
        self.receiverRef.deposit(from: <-withdrawn)
    }
}
