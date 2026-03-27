import "PrizeLinkedAccounts"

/// Claim a CriticalOps capability from the deployer's inbox and store it locally.
///
/// Run this after the deployer has run issue_critical_ops_capability.cdc.
/// The stored capability is used by draw/start_draw.cdc, draw/complete_draw.cdc,
/// emergency/enable_emergency_mode.cdc, and fees/withdraw_protocol_fee.cdc.
///
/// Signer: ops account receiving the capability
/// Parameter: adminAddress — the deployer account that published the capability
transaction(adminAddress: Address) {
    prepare(signer: auth(Storage, Inbox) &Account) {
        let cap = signer.inbox.claim<auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin>(
            "PrizeLinkedAccountsAdminCriticalOps",
            provider: adminAddress
        ) ?? panic("No CriticalOps capability found in inbox from ".concat(adminAddress.toString()))

        signer.storage.save(cap, to: /storage/PrizeLinkedAccountsAdminCriticalOps)

        log("Claimed and stored CriticalOps capability from ".concat(adminAddress.toString()))
    }
}
