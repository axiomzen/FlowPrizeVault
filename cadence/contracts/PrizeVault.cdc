/*
PrizeVault - A generic no-loss lottery system on Flow blockchain

This contract uses DeFi Actions to abstract yield generation strategies.
Pools are configured to work with any yield protocol by providing DeFi Actions connectors
(Sink, Source, PriceOracle, Swapper) through the PoolConfig struct.

Users deposit tokens into a pool which generates yield via configurable strategies.
The yield is periodically distributed as prizes to randomly selected depositors.
Users can withdraw their principal deposits at any time (subject to protocol constraints).

Key features:
- Fully protocol-agnostic design
- Generic yield generation via DeFi Actions interfaces
- Multiple simultaneous pools supported
- Prize distribution using commit-reveal randomness
- Flexible withdrawal strategies (delayed or instant swap)

Protocol implementations (Increment, Ankr, etc.) should be created in separate contracts
and passed to the PoolConfig when creating a pool.
*/

import "FungibleToken"
import "FlowToken"
import "RandomConsumer"
import "DeFiActions"

access(all) contract PrizeVault {
    
    // ========================================
    // Storage Paths
    // ========================================
    
    access(all) let PoolPositionCollectionStoragePath: StoragePath
    access(all) let PoolPositionCollectionPublicPath: PublicPath
    
    // ========================================
    // Pool Storage
    // ========================================
    
    access(self) var pools: @{UInt64: Pool}
    access(self) var nextPoolID: UInt64
    
    // ========================================
    // Events
    // ========================================
    
    access(all) event PoolCreated(poolID: UInt64, assetType: String, minDeposit: UFix64)
    access(all) event Deposited(poolID: UInt64, receiverID: UInt64, amount: UFix64)
    access(all) event InstantWithdrawn(poolID: UInt64, receiverID: UInt64, amount: UFix64)
    access(all) event PrizeDrawCommitted(poolID: UInt64, prizeAmount: UFix64, commitBlock: UInt64, receiptID: UInt64)
    access(all) event PrizeAwarded(poolID: UInt64, winnerReceiverID: UInt64, amount: UFix64, round: UInt64, commitBlock: UInt64, receiptID: UInt64)
    
    // ========================================
    // Configuration Structures
    // ========================================
    
    /// PoolConfig
    ///
    /// Configuration struct defining how a Pool operates via DeFi Actions connectors
    ///
    access(all) struct PoolConfig {
        /// Asset type accepted by this pool
        access(all) let assetType: Type
        
        /// Sink for yield generation (stake, farm, lend, etc.)
        access(all) let yieldSink: {DeFiActions.Sink}
        
        /// Source for yield withdrawals (unstake, harvest, etc.)
        access(all) let yieldSource: {DeFiActions.Source}
        
        /// Oracle for price/exchange rate queries
        access(all) let priceOracle: {DeFiActions.PriceOracle}?
        
        /// Optional swapper for instant withdrawals (DEX)
        access(all) let instantSwapper: {DeFiActions.Swapper}?
        
        /// Minimum deposit requirement
        access(all) let minimumDeposit: UFix64
        
        /// Blocks between prize draws
        access(all) let blocksPerDraw: UInt64
        
        /// Unique identifier for tracking
        access(all) let uniqueID: DeFiActions.UniqueIdentifier
        
        init(
            assetType: Type,
            yieldSink: {DeFiActions.Sink},
            yieldSource: {DeFiActions.Source},
            priceOracle: {DeFiActions.PriceOracle}?,
            instantSwapper: {DeFiActions.Swapper}?,
            minimumDeposit: UFix64,
            blocksPerDraw: UInt64,
            uniqueID: DeFiActions.UniqueIdentifier
        ) {
            self.assetType = assetType
            self.yieldSink = yieldSink
            self.yieldSource = yieldSource
            self.priceOracle = priceOracle
            self.instantSwapper = instantSwapper
            self.minimumDeposit = minimumDeposit
            self.blocksPerDraw = blocksPerDraw
            self.uniqueID = uniqueID
        }
    }
    
    // ========================================
    // Pool Resource
    // ========================================
    
    /// Prize draw receipt for commit-reveal randomness
    access(all) resource PrizeDrawReceipt {
        access(all) let prizeAmount: UFix64
        access(self) var request: @RandomConsumer.Request?
        
        init(prizeAmount: UFix64, request: @RandomConsumer.Request) {
            self.prizeAmount = prizeAmount
            self.request <- request
        }
        
        access(all) view fun getRequestBlock(): UInt64? {
            return self.request?.block
        }
        
        access(contract) fun popRequest(): @RandomConsumer.Request {
            let request <- self.request <- nil
            return <- request!
        }
    }
    
    /// Pool
    ///
    /// Generic prize pool resource that uses DeFi Actions for yield generation
    ///
    access(all) resource Pool {
        /// Configuration
        access(self) let config: PoolConfig
        
        /// Pool state - tracked by DepositReceiver UUID
        access(self) let receiverDeposits: {UInt64: UFix64}
        access(self) let receiverPrizes: {UInt64: UFix64}
        access(self) let prizeHistory: {UInt64: UInt64}  // round -> receiverID
        access(self) let registeredReceivers: {UInt64: Bool}
        
        access(all) var totalDeposited: UFix64
        access(all) var totalStaked: UFix64
        access(all) var totalRewardsHarvested: UFix64
        access(all) var totalPrizesDistributed: UFix64
        access(all) var prizeRound: UInt64
        access(all) var lastDrawBlock: UInt64
        access(all) var blocksPerDraw: UInt64
        
        /// Liquid vault for temporary storage
        access(self) var liquidVault: @{FungibleToken.Vault}
        
        /// Prize draw state
        access(self) var pendingDrawReceipt: @PrizeDrawReceipt?
        
        /// Random consumer resource owned by this pool
        access(self) let randomConsumer: @RandomConsumer.Consumer
        
        init(
            config: PoolConfig,
            initialVault: @{FungibleToken.Vault}
        ) {
            pre {
                initialVault.getType() == config.assetType: "Vault type mismatch"
                initialVault.balance == 0.0: "Initial vault must be empty"
            }
            
            self.config = config
            self.receiverDeposits = {}
            self.receiverPrizes = {}
            self.prizeHistory = {}
            self.registeredReceivers = {}
            self.totalDeposited = 0.0
            self.totalStaked = 0.0
            self.totalRewardsHarvested = 0.0
            self.totalPrizesDistributed = 0.0
            self.prizeRound = 0
            self.lastDrawBlock = 0
            self.blocksPerDraw = config.blocksPerDraw
            self.liquidVault <- initialVault
            self.pendingDrawReceipt <- nil
            self.randomConsumer <- RandomConsumer.createConsumer()
        }
        
        /// Register a deposit receiver with the pool
        access(all) fun registerReceiver(receiverID: UInt64) {
            pre {
                self.registeredReceivers[receiverID] == nil: "Receiver already registered"
            }
            self.registeredReceivers[receiverID] = true
        }
        
        /// Deposit tokens into the pool
        access(all) fun deposit(from: @{FungibleToken.Vault}, receiverID: UInt64) {
            pre {
                from.getType() == self.config.assetType: "Invalid vault type"
                from.balance >= self.config.minimumDeposit: "Below minimum deposit"
                self.registeredReceivers[receiverID] == true: "Receiver not registered"
            }
            
            let amount = from.balance
            
            // Deposit to yield sink
            self.config.yieldSink.depositCapacity(
                from: &from as auth(FungibleToken.Withdraw) &{FungibleToken.Vault}
            )
            
            destroy from
            
            // Update state
            let currentDeposit = self.receiverDeposits[receiverID] ?? 0.0
            self.receiverDeposits[receiverID] = currentDeposit + amount
            self.totalDeposited = self.totalDeposited + amount
            self.totalStaked = self.totalStaked + amount
            
            emit Deposited(poolID: self.uuid, receiverID: receiverID, amount: amount)
        }
        
        /// Instant withdrawal via swap
        access(all) fun instantWithdraw(amount: UFix64, minOut: UFix64, receiverID: UInt64): @{FungibleToken.Vault} {
            pre {
                self.registeredReceivers[receiverID] == true: "Receiver not registered"
            }
            
            let receiverDeposit = self.receiverDeposits[receiverID] ?? 0.0
            assert(receiverDeposit >= amount, message: "Insufficient deposit")
            assert(self.totalStaked >= amount, message: "Insufficient staked")
            
            let swapper = self.config.instantSwapper ?? panic("Instant withdrawal not supported")
            
            // Withdraw yield tokens
            let yieldTokens <- self.config.yieldSource.withdrawAvailable(maxAmount: amount)
            
            // Get quote
            let quote = swapper.quoteOut(forProvided: yieldTokens.balance, reverse: false)
            assert(quote.outAmount >= minOut, message: "Slippage too high")
            
            // Swap
            let swapped <- swapper.swap(quote: quote, inVault: <- yieldTokens)
            
            // Update state
            self.receiverDeposits[receiverID] = receiverDeposit - amount
            self.totalDeposited = self.totalDeposited - amount
            self.totalStaked = self.totalStaked - amount
            
            emit InstantWithdrawn(poolID: self.uuid, receiverID: receiverID, amount: swapped.balance)
            
            return <- swapped
        }
        
        /// Calculate available rewards
        access(all) fun calculateAvailableRewards(): UFix64 {
            let yieldBalance = self.config.yieldSource.minimumAvailable()
            
            if let oracle = self.config.priceOracle {
                if let rate = oracle.price(ofToken: self.config.assetType) {
                    let totalValue = yieldBalance * rate
                    let rewards = totalValue - self.totalStaked
                    return rewards > 0.0 ? rewards : 0.0
                }
            }
            
            let rewards = yieldBalance - self.totalStaked
            return rewards > 0.0 ? rewards : 0.0
        }
        
        /// Start prize draw
        access(all) fun startDraw() {
            pre {
                self.canDrawNow(): "Not enough blocks since last draw"
                self.pendingDrawReceipt == nil: "Draw already in progress"
            }
            
            let availableRewards = self.calculateAvailableRewards()
            assert(availableRewards > 0.0, message: "No rewards available")
            
            // Harvest rewards
            let rewards <- self.config.yieldSource.withdrawAvailable(maxAmount: availableRewards)
            self.liquidVault.deposit(from: <- rewards)
            self.totalRewardsHarvested = self.totalRewardsHarvested + availableRewards
            
            // Request randomness
            let randomRequest <- self.randomConsumer.requestRandomness()
            
            let receipt <- create PrizeDrawReceipt(
                prizeAmount: availableRewards,
                request: <- randomRequest
            )
            
            let commitBlock = receipt.getRequestBlock()!
            
            emit PrizeDrawCommitted(
                poolID: self.uuid,
                prizeAmount: availableRewards,
                commitBlock: commitBlock,
                receiptID: receipt.uuid
            )
            
            self.pendingDrawReceipt <-! receipt
            self.lastDrawBlock = getCurrentBlock().height
        }
        
        /// Complete prize draw
        access(all) fun completeDraw() {
            pre {
                self.pendingDrawReceipt != nil: "No draw in progress"
            }
            
            let receipt <- self.pendingDrawReceipt <- nil
            let unwrappedReceipt <- receipt!
            let prizeAmount = unwrappedReceipt.prizeAmount
            let commitBlock = unwrappedReceipt.getRequestBlock()!
            let receiptID = unwrappedReceipt.uuid
            
            // Get random number
            let request <- unwrappedReceipt.popRequest()
            let randomNumber = self.randomConsumer.fulfillRandomRequest(<- request)
            destroy unwrappedReceipt
            
            // Select winner
            let winnerReceiverID = self.selectWeightedWinner(randomNumber: randomNumber)
            
            // Award prize
            let currentPrizes = self.receiverPrizes[winnerReceiverID] ?? 0.0
            self.receiverPrizes[winnerReceiverID] = currentPrizes + prizeAmount
            
            self.prizeRound = self.prizeRound + 1
            self.totalPrizesDistributed = self.totalPrizesDistributed + prizeAmount
            self.prizeHistory[self.prizeRound] = winnerReceiverID
        
            emit PrizeAwarded(
                poolID: self.uuid,
                winnerReceiverID: winnerReceiverID,
                amount: prizeAmount, 
                round: self.prizeRound, 
                commitBlock: commitBlock, 
                receiptID: receiptID
            )
        }
    
        /// Select weighted winner
        access(self) fun selectWeightedWinner(randomNumber: UInt64): UInt64 {
            let receiverIDs = self.receiverDeposits.keys
            assert(receiverIDs.length > 0, message: "No depositors")
            
            if receiverIDs.length == 1 {
                return receiverIDs[0]
            }
            
            var cumulativeSum: [UFix64] = []
            var runningTotal: UFix64 = 0.0
            
            for receiverID in receiverIDs {
                runningTotal = runningTotal + self.receiverDeposits[receiverID]!
                cumulativeSum.append(runningTotal)
            }
            
            let randomValue = UFix64(randomNumber % UInt64(runningTotal * 100000000.0)) / 100000000.0
            
            var winnerIndex = 0
            for i, cumSum in cumulativeSum {
                if randomValue < cumSum {
                    winnerIndex = i
                    break
                }
            }
            
            return receiverIDs[winnerIndex]
        }
    
        /// Check if draw can happen
        access(all) view fun canDrawNow(): Bool {
            return (getCurrentBlock().height - self.lastDrawBlock) >= self.blocksPerDraw
        }
        
        // Getters
        access(all) fun getConfig(): PoolConfig { return self.config }
        access(all) fun getReceiverDeposit(receiverID: UInt64): UFix64 { return self.receiverDeposits[receiverID] ?? 0.0 }
        access(all) fun getReceiverPrizes(receiverID: UInt64): UFix64 { return self.receiverPrizes[receiverID] ?? 0.0 }
        access(all) fun getPrizeWinner(round: UInt64): UInt64? { return self.prizeHistory[round] }
        access(all) fun isDrawInProgress(): Bool { return self.pendingDrawReceipt != nil }
        access(all) fun isReceiverRegistered(receiverID: UInt64): Bool { return self.registeredReceivers[receiverID] == true }
    }
    
    // ========================================
    // Deposit Receiver Collection
    // ========================================
    
    /// Helper struct for returning pool position data
    access(all) struct PoolPosition {
        access(all) let poolID: UInt64
        access(all) let depositBalance: UFix64
        access(all) let prizeBalance: UFix64
        access(all) let totalBalance: UFix64
        
        init(
            poolID: UInt64,
            depositBalance: UFix64,
            prizeBalance: UFix64,
            totalBalance: UFix64
        ) {
            self.poolID = poolID
            self.depositBalance = depositBalance
            self.prizeBalance = prizeBalance
            self.totalBalance = totalBalance
        }
    }
    
    /// Public interface for the collection
    access(all) resource interface PoolPositionCollectionPublic {
        // Pool registration
        access(all) fun getRegisteredPoolIDs(): [UInt64]
        access(all) fun isRegisteredWithPool(poolID: UInt64): Bool
        
        // Deposits
        access(all) fun deposit(poolID: UInt64, from: @{FungibleToken.Vault})
        
        // Withdrawals
        access(all) fun instantWithdrawDeposit(poolID: UInt64, amount: UFix64, minOut: UFix64): @{FungibleToken.Vault}
        access(all) fun instantWithdrawPrize(poolID: UInt64, amount: UFix64, minOut: UFix64): @{FungibleToken.Vault}
        
        // Balance queries
        access(all) fun getDepositBalance(poolID: UInt64): UFix64
        access(all) fun getPrizeBalance(poolID: UInt64): UFix64
        access(all) fun getTotalBalance(poolID: UInt64): UFix64
        
        // Aggregate queries across all pools
        access(all) fun getTotalBalanceAllPools(): UFix64
        access(all) fun getAllPoolBalances(): {UInt64: UFix64}
        access(all) fun getPoolPosition(poolID: UInt64): PoolPosition
        access(all) fun getAllPoolPositions(): [PoolPosition]
        access(all) fun hasActivePosition(): Bool
    }
    
    /// Collection resource that manages deposits across multiple pools
    access(all) resource PoolPositionCollection: PoolPositionCollectionPublic {
        /// Track which pools this collection is registered with
        access(self) let registeredPools: {UInt64: Bool}
        
        init() {
            self.registeredPools = {}
        }
        
        /// Register with a new pool (internal helper)
        access(self) fun registerWithPool(poolID: UInt64) {
            pre {
                self.registeredPools[poolID] == nil: "Already registered with this pool"
            }
            
            // Verify pool exists
            let poolRef = PrizeVault.borrowPoolAuth(poolID: poolID)
                ?? panic("Pool does not exist")
            
            // Register this collection's UUID with the pool
            poolRef.registerReceiver(receiverID: self.uuid)
            
            self.registeredPools[poolID] = true
        }
        
        /// Get all pool IDs this collection is registered with
        access(all) fun getRegisteredPoolIDs(): [UInt64] {
            return self.registeredPools.keys
        }
        
        /// Check if registered with a specific pool
        access(all) fun isRegisteredWithPool(poolID: UInt64): Bool {
            return self.registeredPools[poolID] == true
        }
        
        /// Deposit into a specific pool
        /// Auto-registers with pool if this is the first deposit
        access(all) fun deposit(poolID: UInt64, from: @{FungibleToken.Vault}) {
            // Auto-register if needed
            if self.registeredPools[poolID] == nil {
                self.registerWithPool(poolID: poolID)
            }
            
            let poolRef = PrizeVault.borrowPoolAuth(poolID: poolID)
                ?? panic("Cannot borrow pool")
            
            poolRef.deposit(from: <- from, receiverID: self.uuid)
        }
        
        /// Instant withdrawal of deposits from a specific pool via swap
        access(all) fun instantWithdrawDeposit(
            poolID: UInt64,
            amount: UFix64,
            minOut: UFix64
        ): @{FungibleToken.Vault} {
            pre {
                self.registeredPools[poolID] == true: "Not registered with this pool"
            }
            
            let poolRef = PrizeVault.borrowPoolAuth(poolID: poolID)
                ?? panic("Cannot borrow pool")
            
            return <- poolRef.instantWithdraw(
                amount: amount,
                minOut: minOut,
                receiverID: self.uuid
            )
        }
        
        /// Instant withdrawal of prizes from a specific pool via swap
        access(all) fun instantWithdrawPrize(
            poolID: UInt64,
            amount: UFix64,
            minOut: UFix64
        ): @{FungibleToken.Vault} {
            pre {
                self.registeredPools[poolID] == true: "Not registered with this pool"
            }
            
            let poolRef = PrizeVault.borrowPoolAuth(poolID: poolID)
                ?? panic("Cannot borrow pool")
            
            // Get current prize balance
            let receiverPrize = poolRef.getReceiverPrizes(receiverID: self.uuid)
            assert(receiverPrize >= amount, message: "Insufficient prize balance")
            
            // Deduct prize balance
            // Note: This requires Pool to expose a method to withdraw prizes
            // For now, we'll use the instantWithdraw which handles deposits
            // TODO: Add prize-specific withdrawal to Pool
            return <- poolRef.instantWithdraw(
                amount: amount,
                minOut: minOut,
                receiverID: self.uuid
            )
        }
        
        /// Get deposit balance for a specific pool
        access(all) fun getDepositBalance(poolID: UInt64): UFix64 {
            if self.registeredPools[poolID] == nil {
                return 0.0
            }
            
            let poolRef = PrizeVault.borrowPool(poolID: poolID)
            if poolRef == nil {
                return 0.0
            }
            
            return poolRef!.getReceiverDeposit(receiverID: self.uuid)
        }
        
        /// Get prize balance for a specific pool
        access(all) fun getPrizeBalance(poolID: UInt64): UFix64 {
            if self.registeredPools[poolID] == nil {
                return 0.0
            }
            
            let poolRef = PrizeVault.borrowPool(poolID: poolID)
            if poolRef == nil {
                return 0.0
            }
            
            return poolRef!.getReceiverPrizes(receiverID: self.uuid)
        }
        
        /// Get total balance (deposits + prizes) for a specific pool
        access(all) fun getTotalBalance(poolID: UInt64): UFix64 {
            return self.getDepositBalance(poolID: poolID) + 
                   self.getPrizeBalance(poolID: poolID)
        }
        
        /// Get total balance across ALL registered pools
        access(all) fun getTotalBalanceAllPools(): UFix64 {
            var total: UFix64 = 0.0
            
            for poolID in self.registeredPools.keys {
                total = total + self.getTotalBalance(poolID: poolID)
            }
            
            return total
        }
        
        /// Get balance breakdown for all registered pools
        access(all) fun getAllPoolBalances(): {UInt64: UFix64} {
            let balances: {UInt64: UFix64} = {}
            
            for poolID in self.registeredPools.keys {
                balances[poolID] = self.getTotalBalance(poolID: poolID)
            }
            
            return balances
        }
        
        /// Get detailed position for a specific pool
        access(all) fun getPoolPosition(poolID: UInt64): PoolPosition {
            return PoolPosition(
                poolID: poolID,
                depositBalance: self.getDepositBalance(poolID: poolID),
                prizeBalance: self.getPrizeBalance(poolID: poolID),
                totalBalance: self.getTotalBalance(poolID: poolID)
            )
        }
        
        /// Get detailed positions for all registered pools
        access(all) fun getAllPoolPositions(): [PoolPosition] {
            let positions: [PoolPosition] = []
            
            for poolID in self.registeredPools.keys {
                positions.append(self.getPoolPosition(poolID: poolID))
            }
            
            return positions
        }
        
        /// Check if this collection has any active positions in any pool
        /// Users should call this before destroying to avoid losing funds
        access(all) fun hasActivePosition(): Bool {
            for poolID in self.registeredPools.keys {
                let deposit = self.getDepositBalance(poolID: poolID)
                let prizes = self.getPrizeBalance(poolID: poolID)
                
                if deposit > 0.0 || prizes > 0.0 {
                    return true
                }
            }
            
            return false
        }
    }
    
    // Entitlement that restricts access to the pools via
    // contract API
    access(all) entitlement PoolAccess
    
    // ========================================
    // Factory Functions
    // ========================================
    
    /// Create a generic pool with custom configuration and store it in contract
    access(all) fun createPool(config: PoolConfig): UInt64 {
        let emptyVault <- FlowToken.createEmptyVault(vaultType: Type<@FlowToken.Vault>())
        let pool <- create Pool(
            config: config,
            initialVault: <- emptyVault
        )
        
        let poolID = self.nextPoolID
        self.nextPoolID = self.nextPoolID + 1
        
        emit PoolCreated(
            poolID: poolID,
            assetType: config.assetType.identifier,
            minDeposit: config.minimumDeposit
        )
        
        self.pools[poolID] <-! pool
        return poolID
    }
    
    /// Borrow pool reference (read-only)
    access(all) view fun borrowPool(poolID: UInt64): &Pool? {
        return &self.pools[poolID]
    }
    
    /// Borrow pool reference with authorization
    access(all) fun borrowPoolAuth(poolID: UInt64): auth(PoolAccess) &Pool? {
        return &self.pools[poolID]
    }
    
    /// Get all pool IDs
    access(all) view fun getAllPoolIDs(): [UInt64] {
        return self.pools.keys
    }
    
    /// Create pool position collection
    access(all) fun createPoolPositionCollection(): @PoolPositionCollection {
        return <- create PoolPositionCollection()
    }
    
    // ========================================
    // Contract Initialization
    // ========================================
    
    init() {
        self.PoolPositionCollectionStoragePath = /storage/PrizeVaultPoolPositionCollection
        self.PoolPositionCollectionPublicPath = /public/PrizeVaultPoolPositionCollection
        
        // Initialize pool storage
        self.pools <- {}
        self.nextPoolID = 0
    }
}
