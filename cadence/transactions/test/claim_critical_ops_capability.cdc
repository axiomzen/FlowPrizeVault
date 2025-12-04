import "PrizeSavings"

/// Claim CriticalOps capability from inbox and store it
transaction(adminAddress: Address) {
    prepare(signer: auth(Storage, Inbox) &Account) {
        // Claim the capability from inbox
        let inboxName = "PrizeSavingsAdminCriticalOps"
        let cap = signer.inbox.claim<auth(PrizeSavings.CriticalOps) &PrizeSavings.Admin>(
            inboxName,
            provider: adminAddress
        ) ?? panic("No CriticalOps capability found in inbox")
        
        // Store it in private storage
        let storagePath = /storage/PrizeSavingsAdminCriticalOps
        signer.storage.save(cap, to: storagePath)
        
        log("Claimed and stored CriticalOps capability")
    }
}

