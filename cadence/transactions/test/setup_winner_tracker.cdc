import "PrizeWinnerTracker"

/// Setup a winner tracker on the account
transaction(maxSize: Int) {
    prepare(signer: auth(Storage, Capabilities) &Account) {
        // Check if tracker already exists
        if signer.storage.borrow<&PrizeWinnerTracker.RingBufferTracker>(from: PrizeWinnerTracker.TrackerStoragePath) == nil {
            // Create and save tracker
            let tracker <- PrizeWinnerTracker.createRingBufferTracker(maxSize: maxSize)
            signer.storage.save(<-tracker, to: PrizeWinnerTracker.TrackerStoragePath)

            // Create public capability
            let cap = signer.capabilities.storage.issue<&{PrizeWinnerTracker.WinnerTrackerPublic}>(PrizeWinnerTracker.TrackerStoragePath)
            signer.capabilities.publish(cap, at: PrizeWinnerTracker.TrackerPublicPath)

            log("Created winner tracker with max size ".concat(maxSize.toString()))
        } else {
            log("Winner tracker already exists")
        }
    }
}
