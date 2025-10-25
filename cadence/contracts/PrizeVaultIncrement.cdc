/*
PrizeVault Increment - A no-loss lottery system on Flow blockchain

Users deposit FLOW tokens into the vault. The vault stakes these tokens on Increment Labs
to generate yield. The staking rewards are periodically distributed as prizes to randomly 
selected depositors using Flow's VRF for verifiable randomness.

Users can withdraw their principal deposits at any time (subject to unstaking period).

Key features:
- Deposit FLOW tokens
- Automatic staking via Increment Labs liquid staking
- Prize distribution using commit-reveal randomness
- Principal withdrawal with two-phase process (request + complete)

In essence, users retain ownership of their principal deposits while participating 
in periodic prize draws funded by the staking rewards — creating a lossless lottery model.
*/

import FungibleToken from 0xf233dcee88fe0abe
import FlowToken from 0x1654653399040a61
import RandomConsumer from 0x45caec600164c9e6

import stFlowToken from 0xd6f80565193ad727
import LiquidStaking from 0xd6f80565193ad727

// Increment Finance Swap Contracts
import SwapConfig from 0xb78ef7afa52ff906
import SwapInterfaces from 0xb78ef7afa52ff906
import SwapFactory from 0xb063c16cac85dbd1

access(all) contract PrizeVaultIncrement {
    
    // Constants
    access(all) let minimumDeposit: UFix64
    
    // Events
    access(all) event Deposited(address: Address, amount: UFix64)
    access(all) event WithdrawalRequested(address: Address, amount: UFix64, withdrawalType: String)
    access(all) event Withdrawn(address: Address, amount: UFix64)
    access(all) event InstantWithdrawn(address: Address, stFlowAmount: UFix64, flowReceived: UFix64)
    access(all) event Staked(amount: UFix64, stFlowReceived: UFix64)
    access(all) event UnstakeRequested(amount: UFix64, voucherUUID: UInt64, unlockEpoch: UInt64)
    access(all) event PrizeDrawCommitted(prizeAmount: UFix64, commitBlock: UInt64, receiptID: UInt64)
    access(all) event PrizeAwarded(winner: Address, amount: UFix64, round: UInt64, commitBlock: UInt64, receiptID: UInt64)
    access(all) event DepositReceiverCreated(address: Address)
    access(all) event BlocksPerMonthUpdated(oldValue: UInt64, newValue: UInt64)
    
    // Paths
    access(all) let DepositReceiverStoragePath: StoragePath
    access(all) let DepositReceiverPublicPath: PublicPath
    access(all) let VaultStoragePath: StoragePath
    access(all) let AdminStoragePath: StoragePath
    access(all) let PrizeDrawReceiptStoragePath: StoragePath
    access(all) let WithdrawVoucherCollectionStoragePath: StoragePath
    
    // State
    access(all) var totalDeposited: UFix64
    access(all) var totalStaked: UFix64  // In FLOW terms (original amount staked)
    access(all) var totalRewardsHarvested: UFix64
    access(all) var totalPrizesDistributed: UFix64
    access(all) var prizeRound: UInt64
    access(all) var lastDrawBlock: UInt64  // Block height of last draw
    access(all) var blocksPerMonth: UInt64  // Configurable blocks between draws (~30 days)
    access(self) var monthlyDrawReceipt: @PrizeDrawReceipt?  // Stored receipt for monthly draw
    
    // Mappings
    access(self) let userDeposits: {Address: UFix64}  // Original deposits only
    access(self) let userPrizes: {Address: UFix64}    // Prizes won
    access(self) let pendingWithdrawals: {Address: UFix64}
    access(self) let prizeHistory: {UInt64: Address}
    
    // Main vault to hold all deposited FLOW tokens (liquid FLOW only)
    access(self) let vault: @FlowToken.Vault
    
    // stFlowToken vault to hold staked tokens
    access(self) let stFlowVault: @stFlowToken.Vault
    
    // WithdrawVoucher collection to manage unstaking vouchers
    access(self) let voucherCollection: @LiquidStaking.WithdrawVoucherCollection
    
    // RandomConsumer for commit-reveal randomness
    access(self) let consumer: @RandomConsumer.Consumer
    
    // Receipt resource for prize draw commit-reveal
    access(all) resource PrizeDrawReceipt {
        access(all) let prizeAmount: UFix64
        access(self) var request: @RandomConsumer.Request?
        
        init(prizeAmount: UFix64, request: @RandomConsumer.Request) {
            self.prizeAmount = prizeAmount
            self.request <- request
        }
        
        // Get the block height at which randomness was committed
        access(all) view fun getRequestBlock(): UInt64? {
            return self.request?.block
        }
        
        // Pop the request for fulfillment (can only be called once)
        access(contract) fun popRequest(): @RandomConsumer.Request {
            let request <- self.request <- nil
            return <- request!
        }
    }
    
    // Admin resource to manage contract configuration
    access(all) resource Admin {
        // Commit phase: Start a prize draw (returns receipt to be used in reveal)
        access(all) fun commitPrizeDraw(prizeAmount: UFix64): @PrizeDrawReceipt {
            return <- PrizeVaultIncrement.commitPrize(amount: prizeAmount)
        }
        
        // Reveal phase: Complete the prize draw using the receipt
        access(all) fun revealPrizeDraw(receipt: @PrizeDrawReceipt) {
            PrizeVaultIncrement.revealPrize(receipt: <- receipt)
        }
        
        // Update the blocks per month interval (for adjusting draw frequency)
        // Default: 2592000 blocks ≈ 30 days (at ~1 second block time on Flow)
        access(all) fun setBlocksPerMonth(newBlocksPerMonth: UInt64) {
            assert(newBlocksPerMonth > 0, message: "Blocks per month must be greater than 0")
            assert(newBlocksPerMonth >= 10000, message: "Minimum 10,000 blocks (~3 hours) to prevent spam")
            assert(newBlocksPerMonth <= 5184000, message: "Maximum 5,184,000 blocks (~60 days)")
            
            let oldValue = PrizeVaultIncrement.blocksPerMonth
            PrizeVaultIncrement.blocksPerMonth = newBlocksPerMonth
            
            emit BlocksPerMonthUpdated(oldValue: oldValue, newValue: newBlocksPerMonth)
        }
        
        // Cashout any mature vouchers from the collection
        access(all) fun cashoutMatureVouchers() {
            PrizeVaultIncrement.processMatureVouchers()
        }
    }
    
    // Public interface that users can expose
    access(all) resource interface DepositReceiverPublic {
        access(all) fun deposit(from: @{FungibleToken.Vault})
        access(all) fun requestDepositWithdrawal(amount: UFix64)
        access(all) fun requestPrizeWithdrawal(amount: UFix64)
        access(all) fun completeWithdrawal(): @{FungibleToken.Vault}
        access(all) fun instantWithdrawDeposit(amount: UFix64, minFlowOut: UFix64): @{FungibleToken.Vault}
        access(all) fun getBalance(): UFix64  // Total balance (deposits + prizes)
        access(all) fun getDepositBalance(): UFix64  // Deposits only
        access(all) fun getPrizeBalance(): UFix64  // Prizes only
        access(all) fun getPendingWithdrawal(): UFix64
    }
    
    // DepositReceiver resource that users create to interact with the vault
    access(all) resource DepositReceiver: DepositReceiverPublic {
        // Track user's balance
        access(self) var balance: UFix64
        
        init() {
            self.balance = 0.0
        }
        
        // Deposit FLOW tokens into the vault
        access(all) fun deposit(from: @{FungibleToken.Vault}) {
            // Get the owner's address
            let ownerAddress = self.owner?.address ?? panic("No owner address")
            
            // Cast to FlowToken.Vault
            let flowVault <- from as! @FlowToken.Vault
            let amount = flowVault.balance
            
            // Enforce minimum deposit to prevent dust/sybil attacks
            assert(amount >= PrizeVaultIncrement.minimumDeposit, 
                   message: "Minimum deposit is ".concat(PrizeVaultIncrement.minimumDeposit.toString()).concat(" FLOW"))
            
            // Stake the tokens via Increment Labs
            PrizeVaultIncrement.stakeTokens(flowVault: <- flowVault)
            
            // Update user's balance
            self.balance = self.balance + amount
            
            // Update contract state
            PrizeVaultIncrement.userDeposits[ownerAddress] = self.balance
            PrizeVaultIncrement.totalDeposited = PrizeVaultIncrement.totalDeposited + amount
            
            emit Deposited(address: ownerAddress, amount: amount)
            emit DepositReceiverCreated(address: ownerAddress)
        }
        
        // Request deposit withdrawal: Initiates unstaking from Increment Labs
        // This requires an unstaking period (typically 2-3 epochs) before funds are available
        access(all) fun requestDepositWithdrawal(amount: UFix64) {
            let ownerAddress = self.owner?.address ?? panic("No owner address")
            
            let userDeposit = PrizeVaultIncrement.userDeposits[ownerAddress] ?? 0.0
            assert(userDeposit >= amount, message: "Insufficient deposit balance. Your deposit: ".concat(userDeposit.toString()))
            
            let existingPending = PrizeVaultIncrement.pendingWithdrawals[ownerAddress] ?? 0.0
            assert(existingPending == 0.0, message: "You already have a pending withdrawal. Complete it first.")
            
            // Verify totalStaked accounting (safety check to prevent underflow)
            assert(PrizeVaultIncrement.totalStaked >= amount, message: "Internal error: insufficient totalStaked")
            
            // Update user's deposit balance
            PrizeVaultIncrement.userDeposits[ownerAddress] = userDeposit - amount
            
            // Update totals
            PrizeVaultIncrement.totalDeposited = PrizeVaultIncrement.totalDeposited - amount
            PrizeVaultIncrement.totalStaked = PrizeVaultIncrement.totalStaked - amount
            PrizeVaultIncrement.pendingWithdrawals[ownerAddress] = amount
            
            // Update local balance
            self.balance = PrizeVaultIncrement.userDeposits[ownerAddress]! + (PrizeVaultIncrement.userPrizes[ownerAddress] ?? 0.0)
            
            // Initiate unstaking from Increment Labs
            PrizeVaultIncrement.unstakeTokens(amount: amount)
            
            emit WithdrawalRequested(address: ownerAddress, amount: amount, withdrawalType: "deposit")
        }
        
        // Request prize withdrawal: Withdraws prizes without unstaking
        // This is instant since prizes are already liquid in the vault
        access(all) fun requestPrizeWithdrawal(amount: UFix64) {
            let ownerAddress = self.owner?.address ?? panic("No owner address")
            
            let userPrize = PrizeVaultIncrement.userPrizes[ownerAddress] ?? 0.0
            assert(userPrize >= amount, message: "Insufficient prize balance. Your prizes: ".concat(userPrize.toString()))
            
            let existingPending = PrizeVaultIncrement.pendingWithdrawals[ownerAddress] ?? 0.0
            assert(existingPending == 0.0, message: "You already have a pending withdrawal. Complete it first.")
            
            // Update user's prize balance
            PrizeVaultIncrement.userPrizes[ownerAddress] = userPrize - amount
            PrizeVaultIncrement.pendingWithdrawals[ownerAddress] = amount
            
            // Update local balance
            self.balance = PrizeVaultIncrement.userDeposits[ownerAddress]! + (PrizeVaultIncrement.userPrizes[ownerAddress] ?? 0.0)
            
            // No unstaking needed - prizes are already liquid in the vault
            
            emit WithdrawalRequested(address: ownerAddress, amount: amount, withdrawalType: "prize")
        }
        
        // Complete withdrawal: Transfer FLOW from vault to user
        // For deposit withdrawals, this requires unstaking to be complete
        // For prize withdrawals, this is instant
        access(all) fun completeWithdrawal(): @{FungibleToken.Vault} {
            let ownerAddress = self.owner?.address ?? panic("No owner address")
            
            let pendingAmount = PrizeVaultIncrement.pendingWithdrawals[ownerAddress]
                ?? panic("No pending withdrawal found")
            
            assert(pendingAmount > 0.0, message: "No pending withdrawal")
            
            // Check vault has enough FLOW
            let vaultBalance = PrizeVaultIncrement.vault.balance
            assert(vaultBalance >= pendingAmount, message: "Insufficient FLOW in vault. Unstaking may not be complete yet. Current vault balance: ".concat(vaultBalance.toString()))
            
            // Withdraw from vault to user
            let withdrawn <- PrizeVaultIncrement.withdrawFromVault(amount: pendingAmount)
            
            // Clear pending withdrawal
            PrizeVaultIncrement.pendingWithdrawals[ownerAddress] = 0.0
            
            emit Withdrawn(address: ownerAddress, amount: pendingAmount)
            
            return <- withdrawn
        }
        
        // Instant withdrawal: Swap stFLOW for FLOW using Increment Finance swap
        // This allows users to withdraw immediately without waiting for unstaking period
        // Note: May incur slippage depending on swap pool liquidity
        access(all) fun instantWithdrawDeposit(amount: UFix64, minFlowOut: UFix64): @{FungibleToken.Vault} {
            let ownerAddress = self.owner?.address ?? panic("No owner address")
            
            let userDeposit = PrizeVaultIncrement.userDeposits[ownerAddress] ?? 0.0
            assert(userDeposit >= amount, message: "Insufficient deposit balance. Your deposit: ".concat(userDeposit.toString()))
            
            let existingPending = PrizeVaultIncrement.pendingWithdrawals[ownerAddress] ?? 0.0
            assert(existingPending == 0.0, message: "You already have a pending withdrawal. Complete it first.")
            
            // Verify totalStaked accounting (safety check to prevent underflow)
            assert(PrizeVaultIncrement.totalStaked >= amount, message: "Internal error: insufficient totalStaked")
            
            // Calculate how much stFLOW we need to withdraw
            let stFlowToWithdraw = LiquidStaking.calcStFlowFromFlow(flowAmount: amount)
            
            // Verify we have enough stFLOW
            assert(PrizeVaultIncrement.stFlowVault.balance >= stFlowToWithdraw, 
                   message: "Insufficient stFLOW in vault. stFLOW needed: ".concat(stFlowToWithdraw.toString()))
            
            // Withdraw stFLOW from contract's vault
            let stFlowVault <- PrizeVaultIncrement.stFlowVault.withdraw(amount: stFlowToWithdraw) as! @stFlowToken.Vault
            
            // Perform the swap: stFLOW -> FLOW
            let flowVault <- PrizeVaultIncrement.swapStFlowForFlow(
                stFlowVault: <- stFlowVault, 
                minFlowOut: minFlowOut
            )
            
            let flowReceived = flowVault.balance
            
            // Update user's deposit balance
            PrizeVaultIncrement.userDeposits[ownerAddress] = userDeposit - amount
            
            // Update totals
            PrizeVaultIncrement.totalDeposited = PrizeVaultIncrement.totalDeposited - amount
            PrizeVaultIncrement.totalStaked = PrizeVaultIncrement.totalStaked - amount
            
            // Update local balance
            self.balance = PrizeVaultIncrement.userDeposits[ownerAddress]! + (PrizeVaultIncrement.userPrizes[ownerAddress] ?? 0.0)
            
            emit InstantWithdrawn(address: ownerAddress, stFlowAmount: stFlowToWithdraw, flowReceived: flowReceived)
            
            return <- flowVault
        }
        
        // Get total balance (deposits + prizes) for display
        access(all) fun getBalance(): UFix64 {
            let ownerAddress = self.owner?.address ?? panic("No owner address")
            let deposit = PrizeVaultIncrement.userDeposits[ownerAddress] ?? 0.0
            let prize = PrizeVaultIncrement.userPrizes[ownerAddress] ?? 0.0
            return deposit + prize
        }
        
        // Get deposit balance only
        access(all) fun getDepositBalance(): UFix64 {
            let ownerAddress = self.owner?.address ?? panic("No owner address")
            return PrizeVaultIncrement.userDeposits[ownerAddress] ?? 0.0
        }
        
        // Get prize balance only
        access(all) fun getPrizeBalance(): UFix64 {
            let ownerAddress = self.owner?.address ?? panic("No owner address")
            return PrizeVaultIncrement.userPrizes[ownerAddress] ?? 0.0
        }
        
        access(all) fun getPendingWithdrawal(): UFix64 {
            let ownerAddress = self.owner?.address ?? panic("No owner address")
            return PrizeVaultIncrement.pendingWithdrawals[ownerAddress] ?? 0.0
        }
    }
    
    // Create a new DepositReceiver for users
    access(all) fun createDepositReceiver(): @DepositReceiver {
        return <- create DepositReceiver()
    }
    
    // Internal function to withdraw from vault
    access(contract) fun withdrawFromVault(amount: UFix64): @{FungibleToken.Vault} {
        let withdrawn <- self.vault.withdraw(amount: amount)
        return <- withdrawn
    }
    
    // Internal function to stake tokens via Increment Labs
    access(contract) fun stakeTokens(flowVault: @FlowToken.Vault) {
        let amount = flowVault.balance
        
        // Stake on Increment Labs and receive stFlowToken
        let stFlowReceived <- LiquidStaking.stake(flowVault: <- flowVault)
        let stFlowAmount = stFlowReceived.balance
        
        // Deposit stFlowToken into our vault
        self.stFlowVault.deposit(from: <- stFlowReceived)
        
        // Update total staked (in FLOW terms)
        self.totalStaked = self.totalStaked + amount
        
        emit Staked(amount: amount, stFlowReceived: stFlowAmount)
    }
    
    // Internal function to unstake tokens from Increment Labs
    // Returns a WithdrawVoucher that can be redeemed after the unlock epoch
    access(contract) fun unstakeTokens(amount: UFix64) {
        // Calculate how much stFlowToken we need to unstake
        let stFlowToUnstake = LiquidStaking.calcStFlowFromFlow(flowAmount: amount)
        
        // Withdraw stFlowToken from our vault
        let stFlowVault <- self.stFlowVault.withdraw(amount: stFlowToUnstake) as! @stFlowToken.Vault
        
        // Unstake from Increment Labs - returns a WithdrawVoucher
        let voucher <- LiquidStaking.unstake(stFlowVault: <- stFlowVault)
        
        let voucherUUID = voucher.uuid
        let unlockEpoch = voucher.unlockEpoch
        
        // Store the voucher in our collection
        self.voucherCollection.deposit(voucher: <- voucher)
        
        emit UnstakeRequested(amount: amount, voucherUUID: voucherUUID, unlockEpoch: unlockEpoch)
    }
    
    // Internal function to swap stFLOW for FLOW using Increment Finance
    // This enables instant withdrawals without waiting for the unstaking period
    access(contract) fun swapStFlowForFlow(stFlowVault: @stFlowToken.Vault, minFlowOut: UFix64): @FlowToken.Vault {
        let stFlowAmount = stFlowVault.balance
        
        // Get token keys for identifying which token is which in the pair
        let stFlowKey = SwapConfig.SliceTokenTypeIdentifierFromVaultType(
            vaultTypeIdentifier: Type<@stFlowToken.Vault>().identifier
        )
        let flowKey = SwapConfig.SliceTokenTypeIdentifierFromVaultType(
            vaultTypeIdentifier: Type<@FlowToken.Vault>().identifier
        )
        
        // Get the stFLOW/FLOW pair address from SwapFactory
        let pairAddress = SwapFactory.getPairAddress(token0Key: stFlowKey, token1Key: flowKey)
            ?? panic("stFLOW/FLOW swap pair not found in SwapFactory. The pair may not exist or tokens may need to be swapped in reverse order.")
        
        // Borrow the swap pair public interface
        let swapPairPublicRef = getAccount(pairAddress)
            .capabilities.get<&{SwapInterfaces.PairPublic}>(/public/increment_swap_pair)
            .borrow()
            ?? panic("Could not borrow swap pair public reference. Pair address: ".concat(pairAddress.toString()))
        
        // Calculate expected output amount (for validation)
        let expectedFlowOut = swapPairPublicRef.getAmountOut(amountIn: stFlowAmount, tokenInKey: stFlowKey)
        
        // Verify minimum output (slippage protection)
        assert(expectedFlowOut >= minFlowOut, 
               message: "Slippage too high. Expected: ".concat(expectedFlowOut.toString())
                       .concat(", Minimum: ").concat(minFlowOut.toString()))
        
        // Perform the swap
        // Cast the stFlowVault to FungibleToken.Vault for the swap
        let tokenIn <- stFlowVault as @{FungibleToken.Vault}
        
        // Execute the swap (exactAmountOut: nil means we get all output from input)
        let tokenOut <- swapPairPublicRef.swap(
            vaultIn: <- tokenIn,
            exactAmountOut: nil
        )
        
        // Cast the output back to FlowToken.Vault
        let flowVault <- tokenOut as! @FlowToken.Vault
        
        return <- flowVault
    }
    
    // Process all mature vouchers and deposit FLOW into vault
    access(contract) fun processMatureVouchers() {
        let voucherInfos = self.voucherCollection.getVoucherInfos()
        
        for info in voucherInfos {
            let voucherInfo = info as! {String: AnyStruct}
            let uuid = voucherInfo["uuid"]! as! UInt64
            let unlockEpoch = voucherInfo["unlockEpoch"]! as! UInt64
            let lockedAmount = voucherInfo["lockedFlowAmount"]! as! UFix64
            
            // Check if voucher is mature (can be cashed out)
            // We need to get current epoch from DelegatorManager via LiquidStaking
            // For now, we'll try to cashout and handle the error if not ready
            
            // Withdraw voucher from collection (needs Withdraw entitlement)
            let voucherCollectionRef = (&self.voucherCollection as auth(FungibleToken.Withdraw) &LiquidStaking.WithdrawVoucherCollection)
            let voucher <- voucherCollectionRef.withdraw(uuid: uuid)
            
            // Try to cashout the voucher
            let flowVault <- LiquidStaking.cashoutWithdrawVoucher(voucher: <- voucher)
            
            // Deposit into our vault
            self.vault.deposit(from: <- flowVault)
        }
    }
    
    // Calculate available rewards to harvest
    access(all) fun calculateAvailableRewards(): UFix64 {
        // Get total stFlowToken balance
        let stFlowBalance = self.stFlowVault.balance
        
        // Convert stFlowToken to FLOW value using Increment's exchange rate
        let totalFlowValue = LiquidStaking.calcFlowFromStFlow(stFlowAmount: stFlowBalance)
        
        // Available rewards = current value - originally staked amount
        let rewards = totalFlowValue - self.totalStaked
        
        return rewards > 0.0 ? rewards : 0.0
    }
    
    // Harvest staking rewards by unstaking the profit portion
    access(contract) fun harvestStakingRewards() {
        let availableRewards = self.calculateAvailableRewards()
        
        assert(availableRewards > 0.0, message: "No rewards to harvest")
        
        // Calculate stFlowToken amount for the rewards
        let stFlowToUnstake = LiquidStaking.calcStFlowFromFlow(flowAmount: availableRewards)
        
        // Withdraw stFlowToken from our vault
        let stFlowVault <- self.stFlowVault.withdraw(amount: stFlowToUnstake) as! @stFlowToken.Vault
        
        // Unstake from Increment Labs
        let voucher <- LiquidStaking.unstake(stFlowVault: <- stFlowVault)
        
        // Store the voucher - it will be cashed out later
        self.voucherCollection.deposit(voucher: <- voucher)
        
        self.totalRewardsHarvested = self.totalRewardsHarvested + availableRewards
    }
    
    // PUBLIC FUNCTION: Start monthly prize draw (anyone can call after sufficient blocks have passed)
    access(all) fun startMonthlyDraw() {
        // Check if enough blocks have passed since last draw
        let currentBlock = getCurrentBlock().height
        let blocksSinceLastDraw = currentBlock - self.lastDrawBlock
        assert(
            self.canDrawNow(), 
            message: "Not enough blocks have passed since last draw. Current block: "
                .concat(currentBlock.toString())
                .concat(", Last draw block: ")
                .concat(self.lastDrawBlock.toString())
                .concat(", Blocks since: ")
                .concat(blocksSinceLastDraw.toString())
                .concat(", Required: ")
                .concat(self.blocksPerMonth.toString())
        )
        
        assert(self.monthlyDrawReceipt == nil, message: "Previous monthly draw not completed. Call completeMonthlyDraw() first.")
        
        // Calculate available rewards to distribute
        let availableRewards = self.calculateAvailableRewards()
        assert(availableRewards > 0.0, message: "No rewards available for distribution")
        
        // Harvest the rewards (unstake from Increment)
        self.harvestStakingRewards()
        
        // Note: After calling this, wait for the unstaking period to complete,
        // then call completeMonthlyDraw() to finish the draw and award the prize
        
        // Update last draw block height
        self.lastDrawBlock = currentBlock
        
        // Commit the prize draw (this will be completed later)
        let receipt <- self.commitPrize(amount: availableRewards)
        self.monthlyDrawReceipt <-! receipt
    }
    
    // PUBLIC FUNCTION: Complete monthly prize draw (anyone can call after commitment)
    access(all) fun completeMonthlyDraw() {
        assert(self.monthlyDrawReceipt != nil, message: "No monthly draw in progress. Call startMonthlyDraw() first.")
        
        // First, process any mature vouchers to get FLOW into vault
        self.processMatureVouchers()
        
        // Get the receipt
        let receipt <- self.monthlyDrawReceipt <- nil
        
        // Complete the prize reveal and award
        self.revealPrize(receipt: <- receipt!)
    }
    
    // Commit phase: Lock in the prize amount and request randomness
    access(contract) fun commitPrize(amount: UFix64): @PrizeDrawReceipt {
        assert(self.userDeposits.length > 0, message: "No users with deposits")
        
        // Request randomness from RandomConsumer
        let request <- self.consumer.requestRandomness()
        
        // Create receipt with prize amount and random request
        let receipt <- create PrizeDrawReceipt(
            prizeAmount: amount,
            request: <- request
        )
        
        let commitBlock = receipt.getRequestBlock()!
        
        emit PrizeDrawCommitted(prizeAmount: amount, commitBlock: commitBlock, receiptID: receipt.uuid)
        
        return <- receipt
    }
    
    // Reveal phase: Use receipt to get random number and award prize
    access(contract) fun revealPrize(receipt: @PrizeDrawReceipt) {
        let prizeAmount = receipt.prizeAmount
        let commitBlock = receipt.getRequestBlock()!
        let receiptID = receipt.uuid
        
        // Fulfill the random request to get the random value
        let request <- receipt.popRequest()
        let randomNumber = self.consumer.fulfillRandomRequest(<-request)
        
        // Destroy the receipt
        destroy receipt
        
        // Select winner using weighted random selection
        let winnerAddress = self.selectWeightedWinner(randomNumber: randomNumber)
        
        // Award the prize by increasing winner's prize balance
        let currentPrizes = self.userPrizes[winnerAddress] ?? 0.0
        self.userPrizes[winnerAddress] = currentPrizes + prizeAmount
        
        // Update prize tracking
        self.prizeRound = self.prizeRound + 1
        self.totalPrizesDistributed = self.totalPrizesDistributed + prizeAmount
        self.prizeHistory[self.prizeRound] = winnerAddress
        
        // Emit prize awarded event
        emit PrizeAwarded(
            winner: winnerAddress, 
            amount: prizeAmount, 
            round: self.prizeRound, 
            commitBlock: commitBlock, 
            receiptID: receiptID
        )
    }
    
    // Weighted random selection: Select winner based on deposit amount
    // Each FLOW token = 1 "ticket" in the lottery
    // User with 100 FLOW has 100x better chance than user with 1 FLOW
    access(contract) fun selectWeightedWinner(randomNumber: UInt64): Address {
        let depositors = self.userDeposits.keys
        assert(depositors.length > 0, message: "No depositors")
        
        // Handle single depositor case
        if depositors.length == 1 {
            return depositors[0]
        }
        
        // Build cumulative sum array
        // Example: [10, 70, 20] -> cumulative: [10, 80, 100]
        var cumulativeSum: [UFix64] = []
        var runningTotal: UFix64 = 0.0
        
        for addr in depositors {
            let amount = self.userDeposits[addr]!
            runningTotal = runningTotal + amount
            cumulativeSum.append(runningTotal)
        }
        
        // Convert UInt64 random number to proportional value in [0, totalDeposited)
        // We use modulo to get a value in range [0, runningTotal)
        // For better distribution with large deposits, we scale appropriately
        let randomValue = UFix64(randomNumber % UInt64(runningTotal * 100000000.0)) / 100000000.0
        
        // Find winner using cumulative sum (similar to binary search)
        // The random value will fall into one depositor's range
        var winnerIndex = 0
        for i, cumSum in cumulativeSum {
            if randomValue < cumSum {
                winnerIndex = i
                break
            }
        }
        
        return depositors[winnerIndex]
    }
    
    // Public getters
    access(all) fun getTotalDeposited(): UFix64 {
        return self.totalDeposited
    }
    
    access(all) fun getTotalStaked(): UFix64 {
        return self.totalStaked
    }
    
    access(all) fun getTotalRewardsHarvested(): UFix64 {
        return self.totalRewardsHarvested
    }
    
    access(all) fun getTotalPrizesDistributed(): UFix64 {
        return self.totalPrizesDistributed
    }
    
    access(all) fun getCurrentPrizeRound(): UInt64 {
        return self.prizeRound
    }
    
    access(all) fun getVaultBalance(): UFix64 {
        return self.vault.balance
    }
    
    access(all) fun getStFlowBalance(): UFix64 {
        return self.stFlowVault.balance
    }
    
    access(all) fun getUserDeposit(address: Address): UFix64 {
        let deposit = self.userDeposits[address] ?? 0.0
        let prize = self.userPrizes[address] ?? 0.0
        return deposit + prize
    }
    
    access(all) fun getUserDepositOnly(address: Address): UFix64 {
        return self.userDeposits[address] ?? 0.0
    }
    
    access(all) fun getUserPrizes(address: Address): UFix64 {
        return self.userPrizes[address] ?? 0.0
    }
    
    access(all) fun getUserPendingWithdrawal(address: Address): UFix64 {
        return self.pendingWithdrawals[address] ?? 0.0
    }
    
    access(all) fun getPrizeWinner(round: UInt64): Address? {
        return self.prizeHistory[round]
    }
    
    access(all) fun getLastDrawBlock(): UInt64 {
        return self.lastDrawBlock
    }
    
    access(all) fun getBlocksPerMonth(): UInt64 {
        return self.blocksPerMonth
    }
    
    access(all) fun getCurrentBlock(): UInt64 {
        return getCurrentBlock().height
    }
    
    access(all) fun getBlocksSinceLastDraw(): UInt64 {
        return getCurrentBlock().height - self.lastDrawBlock
    }
    
    access(all) fun getBlocksUntilNextDraw(): UInt64 {
        let blocksSince = self.getBlocksSinceLastDraw()
        if blocksSince >= self.blocksPerMonth {
            return 0
        }
        return self.blocksPerMonth - blocksSince
    }
    
    access(all) fun canDrawNow(): Bool {
        return self.getBlocksSinceLastDraw() >= self.blocksPerMonth
    }
    
    access(all) fun isMonthlyDrawInProgress(): Bool {
        return self.monthlyDrawReceipt != nil
    }
    
    // Get minimum deposit requirement
    access(all) fun getMinimumDeposit(): UFix64 {
        return self.minimumDeposit
    }
    
    // Calculate user's winning probability (returns value between 0.0 and 1.0)
    // Example: 0.05 = 5% chance to win
    access(all) fun getUserWinningChance(address: Address): UFix64 {
        let userDeposit = self.userDeposits[address] ?? 0.0
        
        if userDeposit == 0.0 || self.totalDeposited == 0.0 {
            return 0.0
        }
        
        return userDeposit / self.totalDeposited
    }
    
    // Get total value locked (TVL) in FLOW
    access(all) fun getTotalValueLocked(): UFix64 {
        // TVL = liquid vault balance + staked value
        let stFlowValue = LiquidStaking.calcFlowFromStFlow(stFlowAmount: self.stFlowVault.balance)
        return self.vault.balance + stFlowValue
    }
    
    // Get pending vouchers info
    access(all) fun getPendingVouchers(): [AnyStruct] {
        return self.voucherCollection.getVoucherInfos()
    }
    
    // Get stFlowToken to FLOW exchange rate
    access(all) fun getExchangeRate(): UFix64 {
        // How much FLOW you get for 1 stFlowToken
        return LiquidStaking.calcFlowFromStFlow(stFlowAmount: 1.0)
    }
    
    init() {
        // Initialize constants
        self.minimumDeposit = 1.0  // 1 FLOW minimum to prevent dust/sybil attacks
        
        // Initialize paths
        self.DepositReceiverStoragePath = /storage/PrizeVaultIncrementDepositReceiver
        self.DepositReceiverPublicPath = /public/PrizeVaultIncrementDepositReceiver
        self.VaultStoragePath = /storage/PrizeVaultIncrementMainVault
        self.AdminStoragePath = /storage/PrizeVaultIncrementAdmin
        self.PrizeDrawReceiptStoragePath = /storage/PrizeVaultIncrementDrawReceipt
        self.WithdrawVoucherCollectionStoragePath = /storage/PrizeVaultIncrementVoucherCollection
        
        // Initialize state
        self.totalDeposited = 0.0
        self.totalStaked = 0.0
        self.totalRewardsHarvested = 0.0
        self.totalPrizesDistributed = 0.0
        self.prizeRound = 0
        self.lastDrawBlock = 0  // Allow first draw immediately (0 means never drawn before)
        self.blocksPerMonth = 2592000  // ~30 days at 1 second per block on Flow
        self.monthlyDrawReceipt <- nil
        self.userDeposits = {}
        self.userPrizes = {}
        self.pendingWithdrawals = {}
        self.prizeHistory = {}
        
        // Create the main vault to hold liquid FLOW
        self.vault <- FlowToken.createEmptyVault(vaultType: Type<@FlowToken.Vault>()) as! @FlowToken.Vault
        
        // Create stFlowToken vault to hold staked tokens
        self.stFlowVault <- stFlowToken.createEmptyVault(vaultType: Type<@stFlowToken.Vault>()) as! @stFlowToken.Vault
        
        // Create WithdrawVoucher collection
        self.voucherCollection <- LiquidStaking.createEmptyWithdrawVoucherCollection()
        
        // Initialize RandomConsumer for commit-reveal randomness
        self.consumer <- RandomConsumer.createConsumer()
        
        // Create and save Admin resource
        self.account.storage.save(<- create Admin(), to: self.AdminStoragePath)
    }
}

