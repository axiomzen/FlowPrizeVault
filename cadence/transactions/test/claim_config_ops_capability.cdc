import "PrizeSavings"

/// Claim ConfigOps capability from inbox and store it
transaction(adminAddress: Address) {
    prepare(signer: auth(Storage, Inbox) &Account) {
        // Claim the capability from inbox
        let inboxName = "PrizeSavingsAdminConfigOps"
        let cap = signer.inbox.claim<auth(PrizeSavings.ConfigOps) &PrizeSavings.Admin>(
            inboxName,
            provider: adminAddress
        ) ?? panic("No ConfigOps capability found in inbox")
        
        // Store it in private storage
        let storagePath = /storage/PrizeSavingsAdminConfigOps
        signer.storage.save(cap, to: storagePath)
        
        log("Claimed and stored ConfigOps capability")
    }
}

