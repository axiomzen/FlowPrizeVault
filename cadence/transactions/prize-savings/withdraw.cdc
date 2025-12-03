import PrizeSavings from "../../contracts/PrizeSavings.cdc"
import FungibleToken from "FungibleToken"
import FlowToken from "FlowToken"

/// Withdraw transaction - Withdraws tokens from a PrizeSavings pool
/// Includes both principal and any accrued savings interest
///
/// Parameters:
/// - poolID: The ID of the pool to withdraw from
/// - amount: The amount of tokens to withdraw
transaction(poolID: UInt64, amount: UFix64) {
    
    let collectionRef: &PrizeSavings.PoolPositionCollection
    let receiverRef: &{FungibleToken.Receiver}
    
    prepare(signer: auth(Storage) &Account) {
        // Borrow the collection
        self.collectionRef = signer.storage.borrow<&PrizeSavings.PoolPositionCollection>(
            from: PrizeSavings.PoolPositionCollectionStoragePath
        ) ?? panic("No PoolPositionCollection found")
        
        // Borrow the receiver vault to deposit withdrawn tokens
        self.receiverRef = signer.storage.borrow<&{FungibleToken.Receiver}>(
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

