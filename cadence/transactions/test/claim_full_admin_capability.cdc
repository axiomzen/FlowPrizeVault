import "PrizeLinkedAccounts"

/// Claim full Admin capability from inbox and store it
transaction(adminAddress: Address) {
    prepare(signer: auth(Storage, Inbox) &Account) {
        // Claim the capability from inbox
        let inboxName = "PrizeLinkedAccountsAdminFull"
        let cap = signer.inbox.claim<auth(PrizeLinkedAccounts.ConfigOps, PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin>(
            inboxName,
            provider: adminAddress
        ) ?? panic("No full Admin capability found in inbox")
        
        // Store it in private storage
        let storagePath = /storage/PrizeLinkedAccountsAdminFull
        signer.storage.save(cap, to: storagePath)
        
        log("Claimed and stored full Admin capability")
    }
}

