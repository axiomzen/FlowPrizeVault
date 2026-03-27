import "PrizeLinkedAccounts"
import "FungibleToken"

/// Fund Prize Pool Directly (requires CriticalOps).
///
/// Adds tokens directly to the prize pool, bypassing the yield distribution split.
/// 100% of the funded amount goes to prizes for the next draw.
///
/// Use this to seed a new pool or unblock startDraw when allocatedPrizeYield == 0
/// (e.g., after a zero-APY period or yield source pause).
///
/// Parameters:
///   poolID          — the pool to fund
///   amount          — amount of tokens to add to the prize pool
///   vaultIdentifier — storage path identifier for the signer's token vault
///                     e.g., "flowTokenVault" for FLOW
///                     e.g., "EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750Vault" for pyUSD
///
/// Signer: deployer account OR ops account with CriticalOps capability
transaction(poolID: UInt64, amount: UFix64, vaultIdentifier: String) {

    let adminRef: auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin
    let vaultRef: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}

    prepare(signer: auth(Storage) &Account) {
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

        let vaultPath = StoragePath(identifier: vaultIdentifier)
            ?? panic("Invalid vault storage path identifier: ".concat(vaultIdentifier))

        self.vaultRef = signer.storage.borrow<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(
            from: vaultPath
        ) ?? panic("Could not borrow vault at /storage/".concat(vaultIdentifier))
    }

    execute {
        let tokens <- self.vaultRef.withdraw(amount: amount)

        self.adminRef.fundPoolDirect(
            poolID: poolID,
            destination: PrizeLinkedAccounts.PoolFundingDestination.Prize,
            from: <- tokens,
            purpose: "Direct prize pool funding",
            metadata: nil
        )

        log("Funded prize pool ".concat(poolID.toString()).concat(" with ").concat(amount.toString()).concat(" tokens"))
    }
}
