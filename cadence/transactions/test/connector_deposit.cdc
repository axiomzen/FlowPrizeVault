import "FungibleToken"
import "FlowToken"
import "PrizeLinkedAccounts"
import "PLAPoolConnector"

/// Test transaction: deposits via PLAPoolConnector.Connector's Sink interface.
/// Simulates what PLAStrategy would do when routing borrowed tokens into PLA.
///
/// Pattern: withdraw `amount` into a temp vault, borrow an authorized ref,
/// call depositCapacity(). This mirrors how a Strategy provides a vault ref
/// to its inner Sink.
///
transaction(poolID: UInt64, amount: UFix64) {
    let connector: PLAPoolConnector.Connector
    let tempVaultRef: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}

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

        // Withdraw amount into a temporary vault and store it
        let mainVault = signer.storage.borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(
            from: /storage/flowTokenVault
        ) ?? panic("Could not borrow FlowToken vault")

        let tempVault <- mainVault.withdraw(amount: amount)
        let tempPath = /storage/connectorTestTempVault
        signer.storage.save(<-tempVault, to: tempPath)

        // Borrow authorized ref to the temp vault (all storage ops in prepare)
        self.tempVaultRef = signer.storage.borrow<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(
            from: tempPath
        ) ?? panic("Could not borrow temp vault")
    }

    execute {
        // Deposit via the Sink interface — connector withdraws from.balance
        self.connector.depositCapacity(from: self.tempVaultRef)
    }
}
