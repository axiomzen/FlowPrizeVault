import "PrizeLinkedAccounts"

/// Claim a full Admin capability (CriticalOps + ConfigOps) from the deployer's inbox.
///
/// Run this after the deployer has run issue_full_admin_capability.cdc.
/// The stored capability enables running draw/start_draw_full.cdc, which handles
/// the complete draw cycle in a single transaction.
///
/// Signer: ops account receiving the capability
/// Parameter: adminAddress — the deployer account that published the capability
transaction(adminAddress: Address) {
    prepare(signer: auth(Storage, Inbox) &Account) {
        let cap = signer.inbox.claim<auth(PrizeLinkedAccounts.ConfigOps, PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin>(
            "PrizeLinkedAccountsAdminFull",
            provider: adminAddress
        ) ?? panic("No full Admin capability found in inbox from ".concat(adminAddress.toString()))

        signer.storage.save(cap, to: /storage/PrizeLinkedAccountsAdminFull)

        log("Claimed and stored full Admin capability from ".concat(adminAddress.toString()))
    }
}
