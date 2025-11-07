import PrizeWinnerTracker from "../../contracts/PrizeWinnerTracker.cdc"

/// Setup PrizeWinnerTracker resource
/// 
/// This creates and stores a RingBufferTracker resource that will track
/// lottery winners for pools that reference it.
/// 
/// **Parameters:**
/// - maxSize: Maximum number of winners to track (per pool and globally)
///            Recommended: 100-1000
/// 
/// **CRITICAL**: This should only be called once per account.
/// The tracker will be stored in the caller's account storage.
transaction(maxSize: Int) {
    prepare(signer: auth(Storage, Capabilities, SaveValue, IssueStorageCapabilityController, PublishCapability) &Account) {
        // Check if tracker already exists
        if signer.storage.borrow<&PrizeWinnerTracker.RingBufferTracker>(
            from: PrizeWinnerTracker.TrackerStoragePath
        ) != nil {
            log("⚠️  Tracker already exists, skipping")
            return
        }
        
        // Create tracker (stores last maxSize winners, e.g., 100)
        let tracker <- PrizeWinnerTracker.createRingBufferTracker(maxSize: maxSize)
        signer.storage.save(<- tracker, to: PrizeWinnerTracker.TrackerStoragePath)
        
        // Create public capability so pools can reference it
        let cap = signer.capabilities.storage.issue<&{PrizeWinnerTracker.WinnerTrackerPublic}>(
            PrizeWinnerTracker.TrackerStoragePath
        )
        signer.capabilities.publish(cap, at: PrizeWinnerTracker.TrackerPublicPath)
        
        log("✅ PrizeWinnerTracker created with maxSize: ".concat(maxSize.toString()))
    }
}

