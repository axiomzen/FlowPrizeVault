import "PrizeLinkedAccounts"

/// Issues a full Admin capability (both ConfigOps and CriticalOps) to a delegate account via Inbox
transaction(delegateAddress: Address) {
    prepare(signer: auth(Storage, Capabilities, Inbox) &Account) {
        // Issue capability with both entitlements
        let cap = signer.capabilities.storage.issue<auth(PrizeLinkedAccounts.ConfigOps, PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin>(
            PrizeLinkedAccounts.AdminStoragePath
        )
        
        // Publish to delegate's inbox - they can claim it later
        let inboxName = "PrizeLinkedAccountsAdminFull"
        signer.inbox.publish(cap, name: inboxName, recipient: delegateAddress)
        
        log("Issued full Admin capability to ".concat(delegateAddress.toString()))
    }
}
