import "PrizeLinkedAccounts"

/// Issue a ConfigOps capability to an operator or automation account via Inbox.
///
/// The recipient must run claim_config_ops_capability.cdc to accept it.
/// ConfigOps grants: start next round, update draw interval, update minimum deposit,
/// update prize distribution, cleanup stale entries.
///
/// Signer: deployer account (holds Admin resource at AdminStoragePath)
/// Recipient: ops or automation account address
transaction(delegateAddress: Address) {
    prepare(signer: auth(Storage, Capabilities, Inbox) &Account) {
        let cap = signer.capabilities.storage.issue<auth(PrizeLinkedAccounts.ConfigOps) &PrizeLinkedAccounts.Admin>(
            PrizeLinkedAccounts.AdminStoragePath
        )

        signer.inbox.publish(cap, name: "PrizeLinkedAccountsAdminConfigOps", recipient: delegateAddress)

        log("Issued ConfigOps capability to ".concat(delegateAddress.toString()))
    }
}
