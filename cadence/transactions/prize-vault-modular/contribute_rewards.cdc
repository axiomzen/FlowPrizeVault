import PrizeVaultModular from "../../contracts/PrizeVaultModular.cdc"
import FungibleToken from "FungibleToken"
import FlowToken from "FlowToken"

/// Contribute rewards to a pool (simulating yield or sponsorships)
/// This adds funds to the reward pool that will be distributed
///
/// Parameters:
/// - poolID: The ID of the pool
/// - amount: The amount to contribute
transaction(poolID: UInt64, amount: UFix64) {
    
    let poolRef: auth(PrizeVaultModular.PoolAccess) &PrizeVaultModular.Pool
    let vaultRef: auth(FungibleToken.Withdraw) &FlowToken.Vault
    let signerAddress: Address
    
    prepare(signer: auth(Storage) &Account) {
        self.signerAddress = signer.address
        
        // Borrow the pool
        self.poolRef = PrizeVaultModular.borrowPoolAuth(poolID: poolID)
            ?? panic("Pool does not exist")
        
        // Borrow the vault
        self.vaultRef = signer.storage.borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(
            from: /storage/flowTokenVault
        ) ?? panic("Could not borrow FlowToken vault")
    }
    
    execute {
        // Withdraw and contribute
        let tokens <- self.vaultRef.withdraw(amount: amount)
        self.poolRef.contributeRewards(from: <- tokens, contributor: self.signerAddress)
        
        log("Contributed ".concat(amount.toString()).concat(" to pool ").concat(poolID.toString()))
    }
}

