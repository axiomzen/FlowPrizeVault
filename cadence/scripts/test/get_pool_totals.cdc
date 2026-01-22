import "PrizeLinkedAccounts"

/// Get the total staked amounts and balances for a pool
access(all) fun main(poolID: UInt64): {String: UFix64} {
    let poolRef = PrizeLinkedAccounts.borrowPool(poolID: poolID)
        ?? panic("Pool not found")

    return {
        "allocatedRewards": poolRef.allocatedRewards,
        "prizeBalance": poolRef.getPrizePoolBalance(),
        "totalProtocolFeeForwarded": poolRef.getTotalProtocolFeeForwarded(),
        "totalStaked": poolRef.getTotalAllocatedFunds()
    }
}
