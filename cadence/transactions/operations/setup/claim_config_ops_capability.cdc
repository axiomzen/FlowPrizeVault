import "PrizeLinkedAccounts"

/// Claim a ConfigOps capability from the deployer's inbox and store it locally.
///
/// Run this after the deployer has run issue_config_ops_capability.cdc.
/// The stored capability is used by draw/start_next_round.cdc,
/// config/update_draw_interval.cdc, config/update_minimum_deposit.cdc,
/// config/update_prize_distribution_*.cdc, and config/cleanup_stale_entries.cdc.
///
/// Signer: ops or automation account receiving the capability
/// Parameter: adminAddress — the deployer account that published the capability
transaction(adminAddress: Address) {
    prepare(signer: auth(Storage, Inbox) &Account) {
        let cap = signer.inbox.claim<auth(PrizeLinkedAccounts.ConfigOps) &PrizeLinkedAccounts.Admin>(
            "PrizeLinkedAccountsAdminConfigOps",
            provider: adminAddress
        ) ?? panic("No ConfigOps capability found in inbox from ".concat(adminAddress.toString()))

        signer.storage.save(cap, to: /storage/PrizeLinkedAccountsAdminConfigOps)

        log("Claimed and stored ConfigOps capability from ".concat(adminAddress.toString()))
    }
}
