import "PrizeLinkedAccounts"

/// Issues a CriticalOps-only capability to a delegate account via Inbox
transaction(delegateAddress: Address) {
    prepare(signer: auth(Storage, Capabilities, Inbox) &Account) {
        // Issue capability with only CriticalOps entitlement
        let cap = signer.capabilities.storage.issue<auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin>(
            PrizeLinkedAccounts.AdminStoragePath
        )
        
        // Publish to delegate's inbox - they can claim it later
        let inboxName = "PrizeLinkedAccountsAdminCriticalOps"
        signer.inbox.publish(cap, name: inboxName, recipient: delegateAddress)
        
        log("Issued CriticalOps capability to ".concat(delegateAddress.toString()))
    }
}
