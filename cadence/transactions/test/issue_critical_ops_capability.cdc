import "PrizeSavings"

/// Issues a CriticalOps-only capability to a delegate account via Inbox
transaction(delegateAddress: Address) {
    prepare(signer: auth(Storage, Capabilities, Inbox) &Account) {
        // Issue capability with only CriticalOps entitlement
        let cap = signer.capabilities.storage.issue<auth(PrizeSavings.CriticalOps) &PrizeSavings.Admin>(
            PrizeSavings.AdminStoragePath
        )
        
        // Publish to delegate's inbox - they can claim it later
        let inboxName = "PrizeSavingsAdminCriticalOps"
        signer.inbox.publish(cap, name: inboxName, recipient: delegateAddress)
        
        log("Issued CriticalOps capability to ".concat(delegateAddress.toString()))
    }
}
