import "PrizeLinkedAccounts"

/// Remove all bonus weight from a user
transaction(poolID: UInt64, receiverID: UInt64) {
    let admin: auth(PrizeLinkedAccounts.ConfigOps) &PrizeLinkedAccounts.Admin

    prepare(signer: auth(Storage) &Account) {
        self.admin = signer.storage.borrow<auth(PrizeLinkedAccounts.ConfigOps) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) ?? panic("Could not borrow Admin reference")
    }

    execute {
        self.admin.removeBonusPrizeWeight(
            poolID: poolID,
            receiverID: receiverID
        )
        log("Removed bonus weight from receiver ".concat(receiverID.toString()))
    }
}
