import "PrizeLinkedAccounts"

/// Issues a ConfigOps-only capability to a delegate account via Inbox
transaction(delegateAddress: Address) {
    prepare(signer: auth(Storage, Capabilities, Inbox) &Account) {
        // Issue capability with only ConfigOps entitlement
        let cap = signer.capabilities.storage.issue<auth(PrizeLinkedAccounts.ConfigOps) &PrizeLinkedAccounts.Admin>(
            PrizeLinkedAccounts.AdminStoragePath
        )
        
        // Publish to delegate's inbox - they can claim it later
        let inboxName = "PrizeLinkedAccountsAdminConfigOps"
        signer.inbox.publish(cap, name: inboxName, recipient: delegateAddress)
        
        log("Issued ConfigOps capability to ".concat(delegateAddress.toString()))
    }
}
