import PrizeLinkedAccounts from "../../contracts/PrizeLinkedAccounts.cdc"
import FungibleToken from "FungibleToken"

/// Fund Prize Pool - Directly adds tokens to a pool's prize pool
/// Requires admin access (CriticalOps entitlement)
/// Tokens are deposited into the yield source and tracked as prize allocation
///
/// Parameters:
/// - poolID: The ID of the pool to fund
/// - amount: The amount of tokens to add to the prize pool
/// - vaultPath: Storage path identifier for the token vault (e.g., "flowTokenVault", "EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750Vault")
/// - purpose: Human-readable description of why the prize pool is being funded (e.g., "Marketing sponsorship", "Launch bonus")
transaction(poolID: UInt64, amount: UFix64, vaultPath: String, purpose: String) {

    let adminRef: auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin
    let vaultRef: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}

    prepare(signer: auth(Storage) &Account) {
        // Borrow the admin with CriticalOps entitlement
        self.adminRef = signer.storage.borrow<auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) ?? panic("No PrizeLinkedAccounts Admin found. Only the contract admin can fund the prize pool.")

        // Build the storage path from the identifier and borrow the vault
        let storagePath = StoragePath(identifier: vaultPath)
            ?? panic("Invalid storage path identifier: ".concat(vaultPath))

        self.vaultRef = signer.storage.borrow<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(
            from: storagePath
        ) ?? panic("Could not borrow FungibleToken vault at /storage/".concat(vaultPath))
    }

    execute {
        // Withdraw tokens from the admin's vault
        let tokens <- self.vaultRef.withdraw(amount: amount)

        // Fund the prize pool directly
        self.adminRef.fundPoolDirect(
            poolID: poolID,
            destination: PrizeLinkedAccounts.PoolFundingDestination.Prize,
            from: <- tokens,
            purpose: purpose,
            metadata: nil
        )

        log("Successfully funded prize pool with ".concat(amount.toString()).concat(" tokens for pool ").concat(poolID.toString()))
    }
}
