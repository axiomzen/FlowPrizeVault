import "PrizeLinkedAccounts"

/// Process a batch of receivers for weight capture (Admin only)
/// Returns remaining receivers to process
transaction(poolID: UInt64, limit: Int) {
    
    prepare(signer: auth(Storage) &Account) {
        let admin = signer.storage.borrow<auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) ?? panic("Could not borrow Admin resource")
        
        let remaining = admin.processPoolDrawBatch(poolID: poolID, limit: limit)
        log("Processed batch for pool ".concat(poolID.toString()).concat(", remaining: ").concat(remaining.toString()))
    }
}
