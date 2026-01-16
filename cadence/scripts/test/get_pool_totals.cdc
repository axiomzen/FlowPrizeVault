import "PrizeSavings"

/// Get the total staked amounts and balances for a pool
access(all) fun main(poolID: UInt64): {String: UFix64} {
    let poolRef = PrizeSavings.borrowPool(poolID: poolID)
        ?? panic("Pool not found")

    return {
        "allocatedSavings": poolRef.allocatedSavings,
        "lotteryBalance": poolRef.getLotteryPoolBalance(),
        "totalTreasuryForwarded": poolRef.getTotalTreasuryForwarded(),
        "totalStaked": poolRef.getTotalAllocatedFunds()
    }
}
