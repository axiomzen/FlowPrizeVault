import "PrizeLinkedAccounts"
import "FungibleToken"

/// Fork-test: Withdraw pyUSD from pool 0.
/// Uses string imports so they resolve via mainnet-fork aliases.
///
/// Parameters:
/// - poolID: The pool to withdraw from
/// - amount: Amount to withdraw (use full balance from get_user_shares)
transaction(poolID: UInt64, amount: UFix64) {

    let collectionRef: auth(PrizeLinkedAccounts.PositionOps) &PrizeLinkedAccounts.PoolPositionCollection
    let receiverRef: &{FungibleToken.Receiver}

    prepare(signer: auth(Storage) &Account) {
        self.collectionRef = signer.storage.borrow<auth(PrizeLinkedAccounts.PositionOps) &PrizeLinkedAccounts.PoolPositionCollection>(
            from: PrizeLinkedAccounts.PoolPositionCollectionStoragePath
        ) ?? panic("No PoolPositionCollection found")

        let pyusdVaultPath = StoragePath(identifier: "EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750Vault")
            ?? panic("Invalid pyUSD vault path")

        self.receiverRef = signer.storage.borrow<&{FungibleToken.Receiver}>(
            from: pyusdVaultPath
        ) ?? panic("Could not borrow pyUSD receiver")
    }

    execute {
        let withdrawn <- self.collectionRef.withdraw(poolID: poolID, amount: amount)
        let withdrawnAmount = withdrawn.balance
        self.receiverRef.deposit(from: <-withdrawn)
        log("Withdrew ".concat(withdrawnAmount.toString()).concat(" pyUSD from pool ").concat(poolID.toString()))
    }
}
