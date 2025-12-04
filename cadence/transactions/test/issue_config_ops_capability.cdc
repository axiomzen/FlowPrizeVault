import "PrizeSavings"

/// Issues a ConfigOps-only capability to a delegate account via Inbox
transaction(delegateAddress: Address) {
    prepare(signer: auth(Storage, Capabilities, Inbox) &Account) {
        // Issue capability with only ConfigOps entitlement
        let cap = signer.capabilities.storage.issue<auth(PrizeSavings.ConfigOps) &PrizeSavings.Admin>(
            PrizeSavings.AdminStoragePath
        )
        
        // Publish to delegate's inbox - they can claim it later
        let inboxName = "PrizeSavingsAdminConfigOps"
        signer.inbox.publish(cap, name: inboxName, recipient: delegateAddress)
        
        log("Issued ConfigOps capability to ".concat(delegateAddress.toString()))
    }
}
