import "PrizeSavings"

/// Cleans up stale dictionary entries and ghost receivers from a pool.
/// This is an admin operation that should be called periodically.
///
/// GAS OPTIMIZATION:
/// - Uses forEachKey instead of .keys (avoids O(n) memory copy)
/// - All cleanups have limits for gas management
///
/// @param poolID - The pool to clean up
/// @param limit - Maximum entries to process per cleanup type (for gas management)

transaction(poolID: UInt64, limit: Int) {
    let adminRef: auth(PrizeSavings.ConfigOps) &PrizeSavings.Admin

    prepare(signer: auth(BorrowValue) &Account) {
        self.adminRef = signer.storage.borrow<auth(PrizeSavings.ConfigOps) &PrizeSavings.Admin>(
            from: PrizeSavings.AdminStoragePath
        ) ?? panic("Could not borrow Admin reference")
    }

    execute {
        let result = self.adminRef.cleanupPoolStaleEntries(
            poolID: poolID,
            limit: limit
        )
        
        log("Cleanup completed for pool ".concat(poolID.toString()))
        log("  Ghost receivers cleaned: ".concat((result["ghostReceivers"] ?? 0).toString()))
        log("  User shares cleaned: ".concat((result["userShares"] ?? 0).toString()))
        log("  Pending NFT claims cleaned: ".concat((result["pendingNFTClaims"] ?? 0).toString()))
    }
}
