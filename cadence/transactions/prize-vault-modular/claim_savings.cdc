import PrizeVaultModular from "../../contracts/PrizeVaultModular.cdc"
import FungibleToken from "FungibleToken"
import FlowToken from "FlowToken"

/// Claim accumulated savings interest
///
/// Parameters:
/// - poolID: The ID of the pool
transaction(poolID: UInt64) {
    
    let collectionRef: &PrizeVaultModular.PoolPositionCollection
    let receiverRef: &{FungibleToken.Receiver}
    
    prepare(signer: auth(Storage) &Account) {
        self.collectionRef = signer.storage.borrow<&PrizeVaultModular.PoolPositionCollection>(
            from: PrizeVaultModular.PoolPositionCollectionStoragePath
        ) ?? panic("No PoolPositionCollection found")
        
        self.receiverRef = signer.storage.borrow<&{FungibleToken.Receiver}>(
            from: /storage/flowTokenVault
        ) ?? panic("Could not borrow FlowToken receiver")
    }
    
    execute {
        let interest <- self.collectionRef.claimSavingsInterest(poolID: poolID)
        let amount = interest.balance
        self.receiverRef.deposit(from: <- interest)
        
        log("Claimed ".concat(amount.toString()).concat(" in savings interest from pool ").concat(poolID.toString()))
    }
}

