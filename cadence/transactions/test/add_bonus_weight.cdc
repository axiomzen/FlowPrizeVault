import "PrizeLinkedAccounts"

/// Add to existing bonus prize weight
transaction(poolID: UInt64, receiverID: UInt64, additionalWeight: UFix64, reason: String) {
    let admin: auth(PrizeLinkedAccounts.ConfigOps) &PrizeLinkedAccounts.Admin

    prepare(signer: auth(Storage) &Account) {
        self.admin = signer.storage.borrow<auth(PrizeLinkedAccounts.ConfigOps) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) ?? panic("Could not borrow Admin reference")
    }

    execute {
        self.admin.addBonusPrizeWeight(
            poolID: poolID,
            receiverID: receiverID,
            additionalWeight: additionalWeight,
            reason: reason
        )
        log("Added bonus weight ".concat(additionalWeight.toString()).concat(" to receiver ").concat(receiverID.toString()))
    }
}
