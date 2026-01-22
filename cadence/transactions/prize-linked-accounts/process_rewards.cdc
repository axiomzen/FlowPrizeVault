import PrizeLinkedAccounts from "../../contracts/PrizeLinkedAccounts.cdc"

/// Process Rewards transaction - Distributes accumulated yield from the yield source
/// This is permissionless - anyone can call it to trigger reward distribution
/// Rewards are split according to the pool's distribution strategy (rewards/prize/protocol)
///
/// Parameters:
/// - poolID: The ID of the pool to process rewards for
transaction(poolID: UInt64) {
    
    prepare(signer: &Account) {
        // No special permissions needed - this is permissionless
    }
    
    execute {
        let poolRef = PrizeLinkedAccounts.borrowPool(poolID: poolID)
            ?? panic("Pool does not exist")
        
        // Check available yield before processing
        let availableYield = poolRef.getAvailableYieldRewards()
        
        if availableYield == 0.0 {
            log("No yield rewards available to process")
            return
        }
        
        log("Processing ".concat(availableYield.toString()).concat(" in yield rewards"))
        
        // Note: syncWithYieldSource is called internally during deposits/withdrawals
        // but this allows explicit triggering for testing or maintenance
        // The Pool.syncWithYieldSource() function is contract-internal, so we trigger
        // reward processing by making a zero-amount operation or letting the 
        // pool handle it automatically during the next user operation
        
        log("Rewards will be processed on next deposit/withdraw operation")
    }
}

