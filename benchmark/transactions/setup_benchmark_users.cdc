
import "PrizeLinkedAccounts"
import "FungibleToken"
import "FlowToken"

/// Creates multiple PoolPositionCollections and deposits for benchmarking
/// Each iteration creates a new collection resource with a unique UUID
/// startIndex allows batched creation without overwriting previous users
transaction(poolID: UInt64, userCount: Int, depositAmount: UFix64, startIndex: Int) {

    let vaultRef: auth(FungibleToken.Withdraw) &FlowToken.Vault
    let adminStorageRef: auth(Storage, Capabilities) &Account

    prepare(signer: auth(Storage, Capabilities) &Account) {
        self.vaultRef = signer.storage.borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(
            from: /storage/flowTokenVault
        ) ?? panic("Could not borrow FlowToken vault")

        self.adminStorageRef = signer
    }

    execute {
        var created = 0
        var userIndex = startIndex

        // Create userCount separate PoolPositionCollections
        // Store them at unique paths to simulate different users
        while created < userCount {
            // Create a new collection
            let collection <- PrizeLinkedAccounts.createPoolPositionCollection()

            // Generate a unique storage path for this "user"
            let pathStr = "benchmarkUser".concat(userIndex.toString())
            let storagePath = StoragePath(identifier: pathStr)!

            // Save the collection
            self.adminStorageRef.storage.save(<-collection, to: storagePath)

            // Borrow it back to make a deposit
            let collectionRef = self.adminStorageRef.storage.borrow<auth(PrizeLinkedAccounts.PositionOps) &PrizeLinkedAccounts.PoolPositionCollection>(
                from: storagePath
            )!

            // Withdraw tokens and deposit
            let tokens <- self.vaultRef.withdraw(amount: depositAmount)
            collectionRef.deposit(poolID: poolID, from: <-tokens)

            created = created + 1
            userIndex = userIndex + 1
        }

        log("Created ".concat(userCount.toString()).concat(" benchmark users starting at index ").concat(startIndex.toString()))
    }
}
