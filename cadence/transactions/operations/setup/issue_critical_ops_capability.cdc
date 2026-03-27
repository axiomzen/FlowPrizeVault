import "PrizeLinkedAccounts"

/// Issue a CriticalOps capability to an operator account via Inbox.
///
/// The recipient must run claim_critical_ops_capability.cdc to accept it.
/// CriticalOps grants: start draw, complete draw, enable/disable emergency mode,
/// withdraw unclaimed protocol fees, update distribution strategy.
///
/// Signer: deployer account (holds Admin resource at AdminStoragePath)
/// Recipient: ops account address
transaction(delegateAddress: Address) {
    prepare(signer: auth(Storage, Capabilities, Inbox) &Account) {
        let cap = signer.capabilities.storage.issue<auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin>(
            PrizeLinkedAccounts.AdminStoragePath
        )

        signer.inbox.publish(cap, name: "PrizeLinkedAccountsAdminCriticalOps", recipient: delegateAddress)

        log("Issued CriticalOps capability to ".concat(delegateAddress.toString()))
    }
}
