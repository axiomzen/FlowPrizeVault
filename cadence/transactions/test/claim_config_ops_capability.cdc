import "PrizeLinkedAccounts"

/// Claim ConfigOps capability from inbox and store it
transaction(adminAddress: Address) {
    prepare(signer: auth(Storage, Inbox) &Account) {
        // Claim the capability from inbox
        let inboxName = "PrizeLinkedAccountsAdminConfigOps"
        let cap = signer.inbox.claim<auth(PrizeLinkedAccounts.ConfigOps) &PrizeLinkedAccounts.Admin>(
            inboxName,
            provider: adminAddress
        ) ?? panic("No ConfigOps capability found in inbox")
        
        // Store it in private storage
        let storagePath = /storage/PrizeLinkedAccountsAdminConfigOps
        signer.storage.save(cap, to: storagePath)
        
        log("Claimed and stored ConfigOps capability")
    }
}

