import "PrizeLinkedAccounts"

/// Issue a full Admin capability (CriticalOps + ConfigOps) to an operator account via Inbox.
///
/// The recipient must run claim_full_admin_capability.cdc to accept it.
/// Use this for accounts that run the complete draw cycle (start_draw_full.cdc),
/// which requires both CriticalOps and ConfigOps.
///
/// Signer: deployer account (holds Admin resource at AdminStoragePath)
/// Recipient: ops account address
transaction(delegateAddress: Address) {
    prepare(signer: auth(Storage, Capabilities, Inbox) &Account) {
        let cap = signer.capabilities.storage.issue<auth(PrizeLinkedAccounts.ConfigOps, PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin>(
            PrizeLinkedAccounts.AdminStoragePath
        )

        signer.inbox.publish(cap, name: "PrizeLinkedAccountsAdminFull", recipient: delegateAddress)

        log("Issued full Admin capability to ".concat(delegateAddress.toString()))
    }
}
