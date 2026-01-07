/*
PrizeWinnerTracker - Pluggable Winner History Tracking

A separate contract that can be optionally plugged into PrizeVaultModular
to track lottery winners without coupling the core logic.

Design Principles:
- Interface-based (can swap implementations)
- Ring buffer (fixed size, efficient memory)
- Read-only public access
- Optional (PrizeVault works without it)
*/

access(all) contract PrizeWinnerTracker {
    
    // ========================================
    // Storage Paths
    // ========================================
    
    access(all) let TrackerStoragePath: StoragePath
    access(all) let TrackerPublicPath: PublicPath
    
    // ========================================
    // Events
    // ========================================
    
    access(all) event WinnerRecorded(
        poolID: UInt64,
        round: UInt64,
        winner: Address,
        amount: UFix64,
        nftIDs: [UInt64],
        timestamp: UFix64,
        blockHeight: UInt64
    )
    
    // ========================================
    // Winner Record Structure
    // ========================================
    
    access(all) struct WinnerRecord {
        access(all) let poolID: UInt64
        access(all) let round: UInt64
        access(all) let winner: Address
        access(all) let amount: UFix64
        access(all) let nftIDs: [UInt64]
        access(all) let timestamp: UFix64
        access(all) let blockHeight: UInt64
        
        init(
            poolID: UInt64,
            round: UInt64,
            winner: Address,
            amount: UFix64,
            nftIDs: [UInt64],
            timestamp: UFix64,
            blockHeight: UInt64
        ) {
            self.poolID = poolID
            self.round = round
            self.winner = winner
            self.amount = amount
            self.nftIDs = nftIDs
            self.timestamp = timestamp
            self.blockHeight = blockHeight
        }
    }
    
    // ========================================
    // Winner Tracker Interface
    // ========================================
    
    /// Interface that any winner tracking implementation must follow
    access(all) resource interface WinnerTrackerPublic {
        access(all) fun recordWinner(
            poolID: UInt64,
            round: UInt64,
            winner: Address,
            amount: UFix64,
            nftIDs: [UInt64]
        )
        
        access(all) fun getRecentWinners(poolID: UInt64, limit: Int): [WinnerRecord]
        access(all) fun getAllRecentWinners(limit: Int): [WinnerRecord]
        access(all) fun getWinnerCount(poolID: UInt64): Int
        access(all) fun getTotalWinnerCount(): Int
        access(all) fun getNFTWinnersCount(poolID: UInt64): Int
        access(all) fun getAllNFTWinnersCount(): Int
    }
    
    // ========================================
    // Ring Buffer Implementation
    // ========================================
    
    /// Efficient ring buffer that stores last N winners per pool
    access(all) resource RingBufferTracker: WinnerTrackerPublic {
        access(self) let maxSize: Int
        access(self) let winnersByPool: {UInt64: [WinnerRecord]}
        access(self) var allWinners: [WinnerRecord]  // Global recent winners
        access(self) var nextIndex: Int  // For ring buffer rotation
        
        init(maxSize: Int) {
            pre {
                maxSize > 0 && maxSize <= 1000: "Max size must be between 1 and 1000"
            }
            self.maxSize = maxSize
            self.winnersByPool = {}
            self.allWinners = []
            self.nextIndex = 0
        }
        
        access(all) fun recordWinner(
            poolID: UInt64,
            round: UInt64,
            winner: Address,
            amount: UFix64,
            nftIDs: [UInt64]
        ) {
            let record = WinnerRecord(
                poolID: poolID,
                round: round,
                winner: winner,
                amount: amount,
                nftIDs: nftIDs,
                timestamp: getCurrentBlock().timestamp,
                blockHeight: getCurrentBlock().height
            )
            
            // Add to pool-specific list
            if self.winnersByPool[poolID] == nil {
                self.winnersByPool[poolID] = []
            }
            
            var poolWinners = self.winnersByPool[poolID]!
            poolWinners.append(record)
            
            // Keep only last maxSize winners per pool
            if poolWinners.length > self.maxSize {
                let _ = poolWinners.remove(at: 0)
            }
            
            self.winnersByPool[poolID] = poolWinners
            
            // Add to global list (ring buffer)
            if self.allWinners.length < self.maxSize {
                // Still filling up
                self.allWinners.append(record)
            } else {
                // Replace oldest (ring buffer)
                self.allWinners[self.nextIndex] = record
                self.nextIndex = (self.nextIndex + 1) % self.maxSize
            }
            
            emit WinnerRecorded(
                poolID: poolID,
                round: round,
                winner: winner,
                amount: amount,
                nftIDs: nftIDs,
                timestamp: record.timestamp,
                blockHeight: record.blockHeight
            )
        }
        
        access(all) fun getRecentWinners(poolID: UInt64, limit: Int): [WinnerRecord] {
            let winners = self.winnersByPool[poolID] ?? []
            
            if limit <= 0 || limit >= winners.length {
                return winners
            }
            
            // Return last 'limit' winners
            let startIndex = winners.length - limit
            var result: [WinnerRecord] = []
            
            var i = startIndex
            while i < winners.length {
                result.append(winners[i])
                i = i + 1
            }
            
            return result
        }
        
        access(all) fun getAllRecentWinners(limit: Int): [WinnerRecord] {
            if limit <= 0 || limit >= self.allWinners.length {
                return self.allWinners
            }
            
            // Return last 'limit' winners
            let startIndex = self.allWinners.length - limit
            var result: [WinnerRecord] = []
            
            var i = startIndex
            while i < self.allWinners.length {
                result.append(self.allWinners[i])
                i = i + 1
            }
            
            return result
        }
        
        access(all) fun getWinnerCount(poolID: UInt64): Int {
            return (self.winnersByPool[poolID] ?? []).length
        }
        
        access(all) fun getTotalWinnerCount(): Int {
            return self.allWinners.length
        }
        
        access(all) fun getNFTWinnersCount(poolID: UInt64): Int {
            let winners = self.winnersByPool[poolID] ?? []
            var count = 0
            for winner in winners {
                if winner.nftIDs.length > 0 {
                    count = count + 1
                }
            }
            return count
        }
        
        access(all) fun getAllNFTWinnersCount(): Int {
            var count = 0
            for winner in self.allWinners {
                if winner.nftIDs.length > 0 {
                    count = count + 1
                }
            }
            return count
        }
    }
    
    // ========================================
    // Factory Functions
    // ========================================
    
    access(all) fun createRingBufferTracker(maxSize: Int): @RingBufferTracker {
        return <- create RingBufferTracker(maxSize: maxSize)
    }
    
    // ========================================
    // Helper Functions
    // ========================================
    
    /// Get tracker from an account (if it exists)
    access(all) fun borrowTracker(account: Address): &{WinnerTrackerPublic}? {
        return getAccount(account)
            .capabilities.borrow<&{WinnerTrackerPublic}>(
                PrizeWinnerTracker.TrackerPublicPath
            )
    }
    
    // ========================================
    // Initialization
    // ========================================
    
    init() {
        self.TrackerStoragePath = /storage/PrizeWinnerTracker
        self.TrackerPublicPath = /public/PrizeWinnerTracker
    }
}

