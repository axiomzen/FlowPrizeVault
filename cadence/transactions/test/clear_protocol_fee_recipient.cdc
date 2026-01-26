import "PrizeLinkedAccounts"

/// Clear the protocol fee recipient (set to nil)
transaction(poolID: UInt64) {
    let admin: auth(PrizeLinkedAccounts.OwnerOnly) &PrizeLinkedAccounts.Admin

    prepare(signer: auth(Storage) &Account) {
        self.admin = signer.storage.borrow<auth(PrizeLinkedAccounts.OwnerOnly) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) ?? panic("Could not borrow Admin reference with OwnerOnly entitlement")
    }

    execute {
        self.admin.setPoolProtocolFeeRecipient(
            poolID: poolID,
            recipientCap: nil
        )
        log("Cleared protocol fee recipient for pool ".concat(poolID.toString()))
    }
}
