import PrizeLinkedAccounts from "../../contracts/PrizeLinkedAccounts.cdc"

/// Protocol statistics structure
/// Note: Protocol auto-forwards to recipient during reward processing, so there's no balance held
access(all) struct ProtocolStats {
    access(all) let totalForwarded: UFix64
    access(all) let recipient: Address?
    access(all) let hasRecipient: Bool
    
    init(
        totalForwarded: UFix64,
        recipient: Address?,
        hasRecipient: Bool
    ) {
        self.totalForwarded = totalForwarded
        self.recipient = recipient
        self.hasRecipient = hasRecipient
    }
}

/// Get protocol statistics for a pool
///
/// Parameters:
/// - poolID: The pool ID to query
///
/// Returns: ProtocolStats struct with protocol information
access(all) fun main(poolID: UInt64): ProtocolStats {
    let poolRef = PrizeLinkedAccounts.borrowPool(poolID: poolID)
        ?? panic("Pool does not exist")
    
    return ProtocolStats(
        totalForwarded: poolRef.getTotalProtocolFeeForwarded(),
        recipient: poolRef.getProtocolRecipient(),
        hasRecipient: poolRef.hasProtocolRecipient()
    )
}

