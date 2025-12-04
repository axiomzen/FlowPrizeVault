import "PrizeSavings"

/// Issues a full Admin capability (both ConfigOps and CriticalOps) to a delegate account via Inbox
transaction(delegateAddress: Address) {
    prepare(signer: auth(Storage, Capabilities, Inbox) &Account) {
        // Issue capability with both entitlements
        let cap = signer.capabilities.storage.issue<auth(PrizeSavings.ConfigOps, PrizeSavings.CriticalOps) &PrizeSavings.Admin>(
            PrizeSavings.AdminStoragePath
        )
        
        // Publish to delegate's inbox - they can claim it later
        let inboxName = "PrizeSavingsAdminFull"
        signer.inbox.publish(cap, name: inboxName, recipient: delegateAddress)
        
        log("Issued full Admin capability to ".concat(delegateAddress.toString()))
    }
}
