import "PrizeLinkedAccounts"
import "FungibleToken"

/// Fund the prize pool directly using Admin with any fungible token type.
/// Tokens bypass the yield distribution split and go 100% to the prize pool.
///
/// Parameters:
/// - poolID: The ID of the pool to fund
/// - amount: The amount of tokens to add to the prize pool
/// - vaultIdentifier: Storage path identifier for the token vault (e.g., "flowTokenVault",
///   "EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750Vault" for pyUSD)
transaction(poolID: UInt64, amount: UFix64, vaultIdentifier: String) {
    
    let adminRef: auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin
    let vaultRef: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}
    
    prepare(signer: auth(Storage) &Account) {
        self.adminRef = signer.storage.borrow<auth(PrizeLinkedAccounts.CriticalOps) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) ?? panic("Could not borrow Admin resource")
        
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
        
        log("Funded prize pool with ".concat(amount.toString()).concat(" tokens from /storage/").concat(vaultIdentifier))
    }
}

