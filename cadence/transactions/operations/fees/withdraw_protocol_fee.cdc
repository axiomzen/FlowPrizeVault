import "PrizeLinkedAccounts"
import FungibleToken from "FungibleToken"

/// Withdraw Unclaimed Protocol Fee (requires CriticalOps).
///
/// Withdraws accumulated protocol fees from the unclaimed vault and sends them
/// to the signer's token receiver. The amount is capped at the available balance —
/// requesting more than is available will not revert, it will withdraw what is available.
///
/// Check available balance first with:
///   flow scripts execute cadence/scripts/prize-linked-accounts/get_protocol_fee_stats.cdc \
///     --args-json '[{"type":"UInt64","value":"0"}]' --network mainnet
///
/// Parameters:
///   poolID  — the pool to withdraw from
///   amount  — amount to withdraw (capped at available balance)
///   purpose — description for logging (e.g., "Q1 treasury transfer")
///
/// Signer: deployer account OR ops account with CriticalOps capability
///   Fees are sent to the signer's /public/flowTokenReceiver
transaction(poolID: UInt64, amount: UFix64, purpose: String) {

    let adminRef: auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin
    let receiverCap: Capability<&{FungibleToken.Receiver}>

    prepare(signer: auth(Storage, Capabilities) &Account) {
        if let directRef = signer.storage.borrow<auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) {
            self.adminRef = directRef
        } else {
            let cap = signer.storage.copy<Capability<auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin>>(
                from: /storage/PrizeLinkedAccountsAdminCriticalOps
            ) ?? panic("No CriticalOps access. Sign with deployer or run setup/claim_critical_ops_capability.cdc first.")
            self.adminRef = cap.borrow()
                ?? panic("CriticalOps capability is invalid or has been revoked.")
        }

        self.receiverCap = signer.capabilities.get<&{FungibleToken.Receiver}>(/public/flowTokenReceiver)
        if !self.receiverCap.check() {
            panic("No FlowToken receiver found at /public/flowTokenReceiver on signer account")
        }
    }

    execute {
        let withdrawn = self.adminRef.withdrawUnclaimedProtocolFee(
            poolID: poolID,
            amount: amount,
            recipient: self.receiverCap
        )

        log("Withdrew ".concat(withdrawn.toString()).concat(" from pool ").concat(poolID.toString())
            .concat(" protocol fee vault. Purpose: ").concat(purpose))
    }
}
