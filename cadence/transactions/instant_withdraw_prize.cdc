import PrizeVault from "../contracts/PrizeVault.cdc"
import FungibleToken from "FungibleToken"
import FlowToken from "FlowToken"

/// Instant withdrawal of prizes via DEX swap (if supported by pool)
/// This allows immediate withdrawal of your prize winnings
/// May incur slippage costs
///
/// Parameters:
/// - poolID: The ID of the pool to withdraw prizes from
/// - amount: The amount of prize tokens to withdraw
/// - minOut: Minimum amount to receive (slippage protection)
transaction(poolID: UInt64, amount: UFix64, minOut: UFix64) {
    
    let collectionRef: &PrizeVault.PoolPositionCollection
    let receiverRef: &FlowToken.Vault
    
    prepare(signer: auth(Storage) &Account) {
        self.collectionRef = signer.storage.borrow<&PrizeVault.PoolPositionCollection>(
            from: PrizeVault.PoolPositionCollectionStoragePath
        ) ?? panic("No PoolPositionCollection found")
        
        self.receiverRef = signer.storage.borrow<&FlowToken.Vault>(
            from: /storage/flowTokenVault
        ) ?? panic("Could not borrow FlowToken vault")
    }
    
    execute {
        let withdrawn <- self.collectionRef.instantWithdrawPrize(
            poolID: poolID,
            amount: amount,
            minOut: minOut
        )
        
        let receivedAmount = withdrawn.balance
        self.receiverRef.deposit(from: <-withdrawn)
        
        log("Instantly withdrew ".concat(receivedAmount.toString()).concat(" prize tokens from pool ").concat(poolID.toString()))
    }
}

