import "PrizeLinkedAccounts"
import "PrizeWinnerTracker"

/// Update pool's winner tracker capability
transaction(poolID: UInt64, trackerAddress: Address) {
    let admin: auth(PrizeLinkedAccounts.ConfigOps) &PrizeLinkedAccounts.Admin

    prepare(signer: auth(Storage) &Account) {
        self.admin = signer.storage.borrow<auth(PrizeLinkedAccounts.ConfigOps) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) ?? panic("Could not borrow Admin reference")
    }

    execute {
        // Get the tracker capability
        let trackerCap = getAccount(trackerAddress)
            .capabilities.get<&{PrizeWinnerTracker.WinnerTrackerPublic}>(PrizeWinnerTracker.TrackerPublicPath)

        self.admin.updatePoolWinnerTracker(
            poolID: poolID,
            newTrackerCap: trackerCap
        )
        log("Updated pool ".concat(poolID.toString()).concat(" winner tracker to address ").concat(trackerAddress.toString()))
    }
}
