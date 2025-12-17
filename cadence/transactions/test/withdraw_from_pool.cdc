import "PrizeSavings"
import "FungibleToken"
import "FlowToken"

/// Withdraw tokens from a PrizeSavings pool (test version)
transaction(poolID: UInt64, amount: UFix64) {
    
    let collectionRef: auth(PrizeSavings.PositionOps) &PrizeSavings.PoolPositionCollection
    let receiverRef: &{FungibleToken.Receiver}
    
    prepare(signer: auth(Storage) &Account) {
        // Borrow the collection with PositionOps entitlement for withdraw
        self.collectionRef = signer.storage.borrow<auth(PrizeSavings.PositionOps) &PrizeSavings.PoolPositionCollection>(
            from: PrizeSavings.PoolPositionCollectionStoragePath
        ) ?? panic("No PoolPositionCollection found")
        
        // Borrow the receiver vault to deposit withdrawn tokens
        self.receiverRef = signer.storage.borrow<&FlowToken.Vault>(
            from: /storage/flowTokenVault
        ) ?? panic("Could not borrow FlowToken receiver")
    }
    
    execute {
        // Withdraw from the pool
        let withdrawn <- self.collectionRef.withdraw(poolID: poolID, amount: amount)
        
        let withdrawnAmount = withdrawn.balance
        
        // Deposit to user's vault
        self.receiverRef.deposit(from: <-withdrawn)
        
        log("Successfully withdrew ".concat(withdrawnAmount.toString()).concat(" tokens from pool ").concat(poolID.toString()))
    }
}
