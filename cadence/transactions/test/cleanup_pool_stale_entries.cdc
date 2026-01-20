import "PrizeLinkedAccounts"

/// Cleans up stale dictionary entries and ghost receivers from a pool.
/// This is an admin operation that should be called periodically.
///
/// Uses cursor-based iteration to handle large pools:
/// 1. First call: startIndex = 0
/// 2. Check result["nextIndex"] and result["totalReceivers"]
/// 3. If nextIndex < totalReceivers, call again with startIndex = nextIndex
/// 4. Repeat until nextIndex >= totalReceivers
///
/// @param poolID - The pool to clean up
/// @param startIndex - Index to start iterating from (0 for first call)
/// @param limit - Maximum receivers to process per call (for gas management)

transaction(poolID: UInt64, startIndex: Int, limit: Int) {
    let adminRef: auth(PrizeLinkedAccounts.ConfigOps) &PrizeLinkedAccounts.Admin

    prepare(signer: auth(BorrowValue) &Account) {
        self.adminRef = signer.storage.borrow<auth(PrizeLinkedAccounts.ConfigOps) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) ?? panic("Could not borrow Admin reference")
    }

    execute {
        let result = self.adminRef.cleanupPoolStaleEntries(
            poolID: poolID,
            startIndex: startIndex,
            limit: limit
        )
        
        let nextIndex = result["nextIndex"] ?? 0
        let totalReceivers = result["totalReceivers"] ?? 0
        
        log("Cleanup completed for pool ".concat(poolID.toString()))
        log("  Ghost receivers cleaned: ".concat((result["ghostReceivers"] ?? 0).toString()))
        log("  User shares cleaned: ".concat((result["userShares"] ?? 0).toString()))
        log("  Pending NFT claims cleaned: ".concat((result["pendingNFTClaims"] ?? 0).toString()))
        log("  Progress: ".concat(nextIndex.toString()).concat(" / ").concat(totalReceivers.toString()))
        
        if nextIndex < totalReceivers {
            log("  NOTE: More entries to process. Call again with startIndex = ".concat(nextIndex.toString()))
        } else {
            log("  All entries processed.")
        }
    }
}
