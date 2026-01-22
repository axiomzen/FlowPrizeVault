import "PrizeLinkedAccounts"

/// Set bonus prize weight for a user (replaces existing)
transaction(poolID: UInt64, receiverID: UInt64, weight: UFix64, reason: String) {
    let admin: auth(PrizeLinkedAccounts.ConfigOps) &PrizeLinkedAccounts.Admin

    prepare(signer: auth(Storage) &Account) {
        self.admin = signer.storage.borrow<auth(PrizeLinkedAccounts.ConfigOps) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) ?? panic("Could not borrow Admin reference")
    }

    execute {
        self.admin.setBonusPrizeWeight(
            poolID: poolID,
            receiverID: receiverID,
            bonusWeight: weight,
            reason: reason
        )
        log("Set bonus weight ".concat(weight.toString()).concat(" for receiver ").concat(receiverID.toString()))
    }
}
