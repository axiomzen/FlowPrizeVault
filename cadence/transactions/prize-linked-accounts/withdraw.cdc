import PrizeLinkedAccounts from "../../contracts/PrizeLinkedAccounts.cdc"
import FungibleToken from "FungibleToken"

/// Withdraw transaction - Withdraws tokens from a PrizeLinkedAccounts pool
/// Works with any FungibleToken vault (FLOW, pyUSD, etc.)
/// Includes both principal and any accrued rewards interest
///
/// Parameters:
/// - poolID: The ID of the pool to withdraw from
/// - amount: The amount of tokens to withdraw
/// - vaultPath: Storage path identifier for the token vault (e.g., "flowTokenVault", "EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750Vault")
transaction(poolID: UInt64, amount: UFix64, vaultPath: String) {

    let collectionRef: auth(PrizeLinkedAccounts.PositionOps) &PrizeLinkedAccounts.PoolPositionCollection
    let receiverRef: &{FungibleToken.Receiver}

    prepare(signer: auth(Storage) &Account) {
        // Borrow the collection with PositionOps entitlement for withdraw
        self.collectionRef = signer.storage.borrow<auth(PrizeLinkedAccounts.PositionOps) &PrizeLinkedAccounts.PoolPositionCollection>(
            from: PrizeLinkedAccounts.PoolPositionCollectionStoragePath
        ) ?? panic("No PoolPositionCollection found")

        // Build the storage path from the identifier and borrow the receiver
        let storagePath = StoragePath(identifier: vaultPath)
            ?? panic("Invalid storage path identifier: ".concat(vaultPath))

        self.receiverRef = signer.storage.borrow<&{FungibleToken.Receiver}>(
            from: storagePath
        ) ?? panic("Could not borrow FungibleToken receiver at /storage/".concat(vaultPath))
    }

    execute {
        // Withdraw from the pool
        let withdrawn <- self.collectionRef.withdraw(poolID: poolID, amount: amount)

        let withdrawnAmount = withdrawn.balance

        // Deposit to user's vault
        self.receiverRef.deposit(from: <-withdrawn)

        log("Successfully withdrew ".concat(withdrawnAmount.toString()).concat(" tokens from pool ").concat(poolID.toString()))
    }
}
