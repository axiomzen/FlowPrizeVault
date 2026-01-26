import "PrizeLinkedAccounts"
import "PrizeWinnerTracker"

/// Clear pool's winner tracker (set to nil)
transaction(poolID: UInt64) {
    let admin: auth(PrizeLinkedAccounts.ConfigOps) &PrizeLinkedAccounts.Admin

    prepare(signer: auth(Storage) &Account) {
        self.admin = signer.storage.borrow<auth(PrizeLinkedAccounts.ConfigOps) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) ?? panic("Could not borrow Admin reference")
    }

    execute {
        self.admin.updatePoolWinnerTracker(
            poolID: poolID,
            newTrackerCap: nil
        )
        log("Cleared winner tracker for pool ".concat(poolID.toString()))
    }
}
