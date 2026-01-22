import "PrizeLinkedAccounts"

/// Start the next prize round, exiting intermission (Admin only)
transaction(poolID: UInt64) {

    prepare(signer: auth(Storage) &Account) {
        let admin = signer.storage.borrow<auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) ?? panic("Could not borrow Admin resource")

        admin.startNextRound(poolID: poolID)
        log("Next round started for pool ".concat(poolID.toString()))
    }
}
