/*
PrizeVault V3 - A no-loss lottery system on Flow blockchain

Users deposit FLOW tokens into the vault. The vault stakes these tokens on Ankr via Flow EVM
to generate yield. The staking rewards are periodically distributed as prizes to randomly 
selected depositors using Flow's VRF for verifiable randomness.

Users can withdraw their principal deposits at any time (subject to unstaking period).

Key features:
- Deposit FLOW tokens
- Automatic staking via Flow EVM (Ankr)
- Prize distribution using commit-reveal randomness
- Principal withdrawal with two-phase process (request + complete)

In essence, users retain ownership of their principal deposits while participating 
in periodic prize draws funded by the staking rewards — creating a lossless lottery model.
*/

import FungibleToken from 0xf233dcee88fe0abe
import FlowToken from 0x1654653399040a61
import RandomConsumer from 0x45caec600164c9e6
import EVM from 0xe467b9dd11fa00df

access(all) contract PrizeVaultV3 {
    
    // Constants
    access(all) let minimumDeposit: UFix64
    
    // Events
    access(all) event Deposited(address: Address, amount: UFix64)
    access(all) event WithdrawalRequested(address: Address, amount: UFix64)
    access(all) event Withdrawn(address: Address, amount: UFix64)
    access(all) event Staked(amount: UFix64)
    access(all) event Unstaked(amount: UFix64)
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
    
    // State
    access(all) var totalDeposited: UFix64
    access(all) var totalStaked: UFix64
    access(all) var totalRewardsHarvested: UFix64
    access(all) var totalPrizesDistributed: UFix64
    access(all) var prizeRound: UInt64
    access(all) var lastDrawBlock: UInt64  // Block height of last draw
    access(all) var blocksPerMonth: UInt64  // Configurable blocks between draws (~30 days)
    access(self) var monthlyDrawReceipt: @PrizeDrawReceipt?  // Stored receipt for monthly draw
    access(self) var totalPendingWithdrawalInCOA: UFix64  // Track user withdrawals in COA to prevent drainage
    
    // Mappings
    access(self) let userDeposits: {Address: UFix64}  // Original deposits only
    access(self) let userPrizes: {Address: UFix64}    // Prizes won
    access(self) let pendingWithdrawals: {Address: UFix64}
    access(self) let prizeHistory: {UInt64: Address}
    
    // Main vault to hold all deposited FLOW tokens
    access(self) let vault: @FlowToken.Vault
    
    // EVM staking pool contract address (Ankr on Flow EVM)
    access(self) let evmStakingPoolAddress: EVM.EVMAddress
    
    // ankrFLOWEVM token address (liquid staking token)
    access(self) let ankrFlowTokenAddress: EVM.EVMAddress
    
    // Ankr ratio feed address (for exchange rate)
    access(self) let ankrRatioFeedAddress: EVM.EVMAddress
    
    // CadenceOwnedAccount for EVM interactions
    access(self) let coa: @EVM.CadenceOwnedAccount
    
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
            return <- PrizeVaultV3.commitPrize(amount: prizeAmount)
        }
        
        // Reveal phase: Complete the prize draw using the receipt
        access(all) fun revealPrizeDraw(receipt: @PrizeDrawReceipt) {
            PrizeVaultV3.revealPrize(receipt: <- receipt)
        }
        
        // Update the blocks per month interval (for adjusting draw frequency)
        // Default: 2592000 blocks ≈ 30 days (at ~1 second block time on Flow)
        access(all) fun setBlocksPerMonth(newBlocksPerMonth: UInt64) {
            assert(newBlocksPerMonth > 0, message: "Blocks per month must be greater than 0")
            assert(newBlocksPerMonth >= 10000, message: "Minimum 10,000 blocks (~3 hours) to prevent spam")
            assert(newBlocksPerMonth <= 5184000, message: "Maximum 5,184,000 blocks (~60 days)")
            
            let oldValue = PrizeVaultV3.blocksPerMonth
            PrizeVaultV3.blocksPerMonth = newBlocksPerMonth
            
            emit BlocksPerMonthUpdated(oldValue: oldValue, newValue: newBlocksPerMonth)
        }
    }
    
    // Public interface that users can expose
    access(all) resource interface DepositReceiverPublic {
        access(all) fun deposit(from: @{FungibleToken.Vault})
        access(all) fun requestDepositWithdrawal(amount: UFix64)
        access(all) fun requestPrizeWithdrawal(amount: UFix64)
        access(all) fun completeWithdrawal(): @{FungibleToken.Vault}
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
            assert(amount >= PrizeVaultV3.minimumDeposit, 
                   message: "Minimum deposit is ".concat(PrizeVaultV3.minimumDeposit.toString()).concat(" FLOW"))
            
            // Deposit into main vault
            let _ = PrizeVaultV3.vault.deposit(from: <- flowVault)
            
            // Stake the tokens via EVM
            PrizeVaultV3.stakeTokens(amount: amount)
            
            // Update user's balance
            self.balance = self.balance + amount
            
            // Update contract state
            PrizeVaultV3.userDeposits[ownerAddress] = self.balance
            PrizeVaultV3.totalDeposited = PrizeVaultV3.totalDeposited + amount
            
            emit Deposited(address: ownerAddress, amount: amount)
            emit DepositReceiverCreated(address: ownerAddress)
        }
        
        // Request deposit withdrawal: Initiates unstaking from Ankr
        // This requires an unstaking period (7-14 days) before funds are available
        access(all) fun requestDepositWithdrawal(amount: UFix64) {
            let ownerAddress = self.owner?.address ?? panic("No owner address")
            
            let userDeposit = PrizeVaultV3.userDeposits[ownerAddress] ?? 0.0
            assert(userDeposit >= amount, message: "Insufficient deposit balance. Your deposit: ".concat(userDeposit.toString()))
            
            let existingPending = PrizeVaultV3.pendingWithdrawals[ownerAddress] ?? 0.0
            assert(existingPending == 0.0, message: "You already have a pending withdrawal. Complete it first.")
            
            // Verify totalStaked accounting (safety check to prevent underflow)
            assert(PrizeVaultV3.totalStaked >= amount, message: "Internal error: insufficient totalStaked")
            
            // Update user's deposit balance
            PrizeVaultV3.userDeposits[ownerAddress] = userDeposit - amount
            
            // Update totals
            PrizeVaultV3.totalDeposited = PrizeVaultV3.totalDeposited - amount
            PrizeVaultV3.totalStaked = PrizeVaultV3.totalStaked - amount
            PrizeVaultV3.pendingWithdrawals[ownerAddress] = amount
            
            // Track this withdrawal in COA counter
            PrizeVaultV3.totalPendingWithdrawalInCOA = PrizeVaultV3.totalPendingWithdrawalInCOA + amount
            
            // Update local balance
            self.balance = PrizeVaultV3.userDeposits[ownerAddress]! + (PrizeVaultV3.userPrizes[ownerAddress] ?? 0.0)
            
            // Initiate unstaking from Ankr
            PrizeVaultV3.unstakeTokens(amount: amount)
            
            emit WithdrawalRequested(address: ownerAddress, amount: amount)
        }
        
        // Request prize withdrawal: Withdraws prizes without unstaking
        // This is instant since prizes are already liquid in the COA (from harvested rewards)
        access(all) fun requestPrizeWithdrawal(amount: UFix64) {
            let ownerAddress = self.owner?.address ?? panic("No owner address")
            
            let userPrize = PrizeVaultV3.userPrizes[ownerAddress] ?? 0.0
            assert(userPrize >= amount, message: "Insufficient prize balance. Your prizes: ".concat(userPrize.toString()))
            
            let existingPending = PrizeVaultV3.pendingWithdrawals[ownerAddress] ?? 0.0
            assert(existingPending == 0.0, message: "You already have a pending withdrawal. Complete it first.")
            
            // Update user's prize balance
            PrizeVaultV3.userPrizes[ownerAddress] = userPrize - amount
            PrizeVaultV3.pendingWithdrawals[ownerAddress] = amount
            
            // Track this withdrawal in COA counter
            PrizeVaultV3.totalPendingWithdrawalInCOA = PrizeVaultV3.totalPendingWithdrawalInCOA + amount
            
            // Update local balance
            self.balance = PrizeVaultV3.userDeposits[ownerAddress]! + (PrizeVaultV3.userPrizes[ownerAddress] ?? 0.0)
            
            // No unstaking needed - prizes are already liquid in the COA
            
            emit WithdrawalRequested(address: ownerAddress, amount: amount)
        }
        
        // Complete withdrawal: Transfer FLOW from COA to user after unstaking period
        access(all) fun completeWithdrawal(): @{FungibleToken.Vault} {
            let ownerAddress = self.owner?.address ?? panic("No owner address")
            
            let pendingAmount = PrizeVaultV3.pendingWithdrawals[ownerAddress]
                ?? panic("No pending withdrawal found")
            
            assert(pendingAmount > 0.0, message: "No pending withdrawal")
            
            // Check COA has enough FLOW from unstaking
            let coaBalance = PrizeVaultV3.getCOABalance()
            assert(coaBalance >= pendingAmount, message: "Insufficient FLOW in COA. Unstaking may not be complete yet. Current COA balance: ".concat(coaBalance.toString()))
            
            // Move FLOW from COA to vault
            PrizeVaultV3.withdrawFromCOA(amount: pendingAmount)
            
            // Withdraw from vault to user
            let withdrawn <- PrizeVaultV3.withdrawFromVault(amount: pendingAmount)
            
            // Note: totalStaked was already decremented in requestWithdrawal()
            // when the shares were burned from Ankr
            
            // Decrement COA pending withdrawal counter (withdrawal complete)
            PrizeVaultV3.totalPendingWithdrawalInCOA = PrizeVaultV3.totalPendingWithdrawalInCOA - pendingAmount
            
            // Clear pending withdrawal
            PrizeVaultV3.pendingWithdrawals[ownerAddress] = 0.0
            
            emit Withdrawn(address: ownerAddress, amount: pendingAmount)
            
            return <- withdrawn
        }
        
        // Get total balance (deposits + prizes) for display
        access(all) fun getBalance(): UFix64 {
            let ownerAddress = self.owner?.address ?? panic("No owner address")
            let deposit = PrizeVaultV3.userDeposits[ownerAddress] ?? 0.0
            let prize = PrizeVaultV3.userPrizes[ownerAddress] ?? 0.0
            return deposit + prize
        }
        
        // Get deposit balance only
        access(all) fun getDepositBalance(): UFix64 {
            let ownerAddress = self.owner?.address ?? panic("No owner address")
            return PrizeVaultV3.userDeposits[ownerAddress] ?? 0.0
        }
        
        // Get prize balance only
        access(all) fun getPrizeBalance(): UFix64 {
            let ownerAddress = self.owner?.address ?? panic("No owner address")
            return PrizeVaultV3.userPrizes[ownerAddress] ?? 0.0
        }
        
        access(all) fun getPendingWithdrawal(): UFix64 {
            let ownerAddress = self.owner?.address ?? panic("No owner address")
            return PrizeVaultV3.pendingWithdrawals[ownerAddress] ?? 0.0
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
    
    // Internal function to stake tokens via EVM (Ankr)
    access(contract) fun stakeTokens(amount: UFix64) {
        // Withdraw FLOW from vault as FlowToken.Vault
        let tokensToStake <- self.vault.withdraw(amount: amount) as! @FlowToken.Vault
        
        // Deposit FLOW into COA - COA needs balance to send value in EVM calls
        let coaRef = (&self.coa as auth(EVM.Call) &EVM.CadenceOwnedAccount)!
        let _ = coaRef.deposit(from: <- tokensToStake)
        
        // Prepare EVM call to stakeCerts() - function signature: 0xac76d450 (from working MetaMask tx)
        let stakeCertsCalldata: [UInt8] = [0xac, 0x76, 0xd4, 0x50]
        
        // Create balance value to send with call
        let value = EVM.Balance(attoflow: 0)
        value.setFLOW(flow: amount)
        
        // Call stakeCerts on EVM staking pool
        // MetaMask uses ~155k gas, so we set 300k to be safe
        let callResult = coaRef.call(
            to: self.evmStakingPoolAddress,
            data: stakeCertsCalldata,
            gasLimit: 300000,
            value: value
        )
        
        assert(
            callResult.status == EVM.Status.successful,
            message: "EVM staking call failed: ".concat(callResult.errorMessage)
        )
        
        // Update total staked
        self.totalStaked = self.totalStaked + amount
        
        emit Staked(amount: amount)
    }
    
    // Internal function to unstake tokens from Ankr EVM
    access(contract) fun unstakeTokens(amount: UFix64) {
        let coaRef = (&self.coa as auth(EVM.Call) &EVM.CadenceOwnedAccount)!
        
        // Prepare EVM call to unstakeCerts(uint256 shares)
        // Function selector for unstakeCerts(uint256): 0x0d904ce2 (from working FlowScan tx)
        // We need to encode: selector (4 bytes) + shares parameter (32 bytes)
        
        // Calculate ankrFLOW shares to unstake based on proportional ownership
        // User's share of pool = (amount / totalDeposited) * totalAnkrFLOWBalance
        // This ensures we never try to unstake more ankrFLOW than we actually have
        let totalAnkrBalance = self.getAnkrFLOWEVMBalance()
        let userProportion = amount / self.totalDeposited
        let sharesToUnstake = userProportion * totalAnkrBalance
        
        // Convert shares to attoflow (wei) for EVM call
        let balance = EVM.Balance(attoflow: 0)
        balance.setFLOW(flow: sharesToUnstake)
        let shares = balance.attoflow // This is the amount in attoflow (18 decimals)
        
        // Encode function call: selector + uint256 parameter (32 bytes, big-endian)
        var calldata: [UInt8] = [0x0d, 0x90, 0x4c, 0xe2] // unstakeCerts(uint256) selector
        
        // Encode shares as 32-byte big-endian uint256
        var sharesBytes: [UInt8] = []
        var remaining = shares
        
        // Convert shares to bytes (big-endian) - build in reverse then reverse
        var tempBytes: [UInt8] = []
        while remaining > 0 {
            tempBytes.append(UInt8(remaining % 256))
            remaining = remaining / 256
        }
        
        // Pad with zeros to 32 bytes and reverse to big-endian
        let paddingNeeded = 32 - tempBytes.length
        var i = 0
        while i < paddingNeeded {
            sharesBytes.append(0)
            i = i + 1
        }
        
        // Append the actual value bytes in reverse (to get big-endian)
        var k = tempBytes.length
        while k > 0 {
            k = k - 1
            sharesBytes.append(tempBytes[k])
        }
        
        // Append shares bytes to calldata
        calldata = calldata.concat(sharesBytes)
        
        // Call unstakeCerts on Ankr EVM contract (no value sent)
        let callResult = coaRef.call(
            to: self.evmStakingPoolAddress,
            data: calldata,
            gasLimit: 300000,
            value: EVM.Balance(attoflow: 0)
        )
        
        assert(
            callResult.status == EVM.Status.successful,
            message: "EVM unstaking call failed: ".concat(callResult.errorMessage)
        )
        
        emit Unstaked(amount: amount)
    }
    
    // Internal function to withdraw FLOW from COA back to vault
    access(contract) fun withdrawFromCOA(amount: UFix64) {
        let coaRef = (&self.coa as auth(EVM.Withdraw) &EVM.CadenceOwnedAccount)!
        
        // Create balance to withdraw
        let balance = EVM.Balance(attoflow: 0)
        balance.setFLOW(flow: amount)
        
        // Withdraw from COA
        let withdrawn <- coaRef.withdraw(balance: balance)
        
        // Deposit into vault
        self.vault.deposit(from: <- withdrawn)
    }
    
    // Query ankrFLOWEVM token balance from EVM
    access(contract) fun getAnkrFLOWEVMBalance(): UFix64 {
        let coaRef = (&self.coa as auth(EVM.Call) &EVM.CadenceOwnedAccount)!
        
        // ERC20 balanceOf(address) function signature: 0x70a08231
        var calldata: [UInt8] = [0x70, 0xa0, 0x82, 0x31]
        
        // Encode COA address as parameter (20 bytes padded to 32 bytes)
        let coaAddress = coaRef.address()
        let addressBytes = coaAddress.bytes
        
        // Pad address to 32 bytes (12 zeros + 20 address bytes)
        var j = 0
        while j < 12 {
            calldata.append(0)
            j = j + 1
        }
        for byte in addressBytes {
            calldata.append(byte)
        }
        
        // Call balanceOf on ankrFLOWEVM token
        let callResult = coaRef.call(
            to: self.ankrFlowTokenAddress,
            data: calldata,
            gasLimit: 100000,
            value: EVM.Balance(attoflow: 0)
        )
        
        assert(
            callResult.status == EVM.Status.successful,
            message: "Failed to query ankrFLOWEVM balance: ".concat(callResult.errorMessage)
        )
        
        // Decode uint256 from return data (32 bytes, big-endian)
        let returnData = callResult.data
        assert(returnData.length >= 32, message: "Invalid return data length")
        
        // Convert bytes to UInt (last 32 bytes are the balance in attoflow)
        var balance: UInt = 0
        var i = 0
        while i < 32 {
            balance = balance * 256 + UInt(returnData[i])
            i = i + 1
        }
        
        // Convert attoflow to FLOW
        let evmBalance = EVM.Balance(attoflow: balance)
        return evmBalance.inFLOW()
    }
    
    // Query exchange rate from Ankr ratio feed (how much FLOW per ankrFLOWEVM)
    access(contract) fun getAnkrExchangeRate(): UFix64 {
        let coaRef = (&self.coa as auth(EVM.Call) &EVM.CadenceOwnedAccount)!
        
        // getRatioFor(address) function signature: 0xa1f1d48d
        var calldata: [UInt8] = [0xa1, 0xf1, 0xd4, 0x8d]
        
        // Encode the ankrFLOWEVM token address as parameter (32 bytes, padded)
        let tokenAddressBytes = self.ankrFlowTokenAddress.bytes
        
        // Pad with 12 zeros (32 bytes total - 20 bytes address = 12 bytes padding)
        var padIndex = 0
        while padIndex < 12 {
            calldata.append(0)
            padIndex = padIndex + 1
        }
        
        // Append the 20-byte token address
        for byte in tokenAddressBytes {
            calldata.append(byte)
        }
        
        // Call getRatioFor(address) on AnkrRatioFeed
        let callResult = coaRef.call(
            to: self.ankrRatioFeedAddress,
            data: calldata,
            gasLimit: 100000,
            value: EVM.Balance(attoflow: 0)
        )
        
        assert(
            callResult.status == EVM.Status.successful,
            message: "Failed to query Ankr exchange rate: ".concat(callResult.errorMessage)
        )
        
        // Decode uint256 from return data (ratio in 18 decimals)
        let returnData = callResult.data
        assert(returnData.length >= 32, message: "Invalid return data length")
        
        // Convert bytes to UInt
        var ratio: UInt = 0
        var i = 0
        while i < 32 {
            ratio = ratio * 256 + UInt(returnData[i])
            i = i + 1
        }
        
        // Convert ratio (18 decimals) to UFix64 (8 decimals)
        // ratio is in format: 1.05 * 10^18 = 1050000000000000000
        // We need to convert to UFix64: 1.05 = 105000000 (8 decimals)
        let rateBalance = EVM.Balance(attoflow: ratio)
        return rateBalance.inFLOW()
    }
    
    // Calculate available rewards to harvest
    access(all) fun calculateAvailableRewards(): UFix64 {
        // Get ankrFLOWEVM balance
        let ankrBalance = self.getAnkrFLOWEVMBalance()
        
        // Get exchange rate
        let rate = self.getAnkrExchangeRate()
        
        // Calculate total FLOW value of ankrFLOWEVM tokens
        let totalValue = ankrBalance * rate
        
        // Available rewards = total value - originally staked amount
        let rewards = totalValue - self.totalStaked
        
        return rewards > 0.0 ? rewards : 0.0
    }
    
    // Harvest staking rewards by unstaking the profit portion
    access(contract) fun harvestStakingRewards() {
        let availableRewards = self.calculateAvailableRewards()
        
        assert(availableRewards > 0.0, message: "No rewards to harvest")
        
        // Unstake the rewards amount (this will be in ankrFLOWEVM tokens)
        // We need to convert FLOW amount to ankrFLOWEVM shares
        let rate = self.getAnkrExchangeRate()
        let sharesToUnstake = availableRewards / rate
        
        // Unstake the shares
        self.unstakeTokens(amount: sharesToUnstake)
        
        // After unstaking completes (a few minutes), the FLOW will be in COA
        // Admin can then move it to vault for prize distribution
        
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
        
        // Harvest the rewards (unstake from Ankr)
        // After unstaking completes (~5 minutes), rewards will be in COA
        // Prizes stay in COA (they're not withdrawable anyway)
        self.harvestStakingRewards()
        
        // Note: After calling this, wait ~5 minutes for unstaking to complete,
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
        
        // Get the receipt
        let receipt <- self.monthlyDrawReceipt <- nil
        
        // Complete the prize reveal and award
        self.revealPrize(receipt: <- receipt!)
    }
    
    // Commit phase: Lock in the prize amount and request randomness
    access(contract) fun commitPrize(amount: UFix64): @PrizeDrawReceipt {
        assert(self.userDeposits.length > 0, message: "No users with deposits")
        
        // Check solvency: prizes stay in COA, so check both vault and available COA rewards
        let totalAvailableForPrizes = self.vault.balance + self.getAvailableRewardsInCOA()
        assert(totalAvailableForPrizes >= amount, 
               message: "Insufficient balance for prize. Available: ".concat(totalAvailableForPrizes.toString())
                       .concat(" FLOW, Prize: ").concat(amount.toString()).concat(" FLOW"))
        
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
    
    // Get COA EVM balance in FLOW
    access(all) fun getCOABalance(): UFix64 {
        let coaRef = &self.coa as &EVM.CadenceOwnedAccount
        let balance = coaRef.balance()
        // Use the built-in conversion method
        return balance.inFLOW()
    }
    
    // Get COA EVM address as hex string
    access(all) fun getCOAAddress(): String {
        let coaRef = &self.coa as &EVM.CadenceOwnedAccount
        return coaRef.address().toString()
    }
    
    // Get the Ankr staking pool EVM address
    access(all) fun getStakingPoolAddress(): String {
        return self.evmStakingPoolAddress.toString()
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
    
    // Get total pending withdrawals in COA (for transparency)
    access(all) fun getTotalPendingWithdrawalInCOA(): UFix64 {
        return self.totalPendingWithdrawalInCOA
    }
    
    // Get available rewards in COA (safe to move to vault)
    access(all) fun getAvailableRewardsInCOA(): UFix64 {
        let coaBalance = self.getCOABalance()
        let availableRewards = coaBalance - self.totalPendingWithdrawalInCOA
        return availableRewards > 0.0 ? availableRewards : 0.0
    }
    
    // Public function to get ankrFLOWEVM balance
    access(all) fun getAnkrFLOWBalance(): UFix64 {
        return self.getAnkrFLOWEVMBalance()
    }
    
    // Public function to get Ankr exchange rate (FLOW per ankrFLOW)
    access(all) fun getAnkrRatio(): UFix64 {
        return self.getAnkrExchangeRate()
    }
    
    // Get ankrFLOWEVM token address
    access(all) fun getAnkrTokenAddress(): String {
        return self.ankrFlowTokenAddress.toString()
    }
    
    // Get total value locked (TVL) in FLOW
    access(all) fun getTotalValueLocked(): UFix64 {
        // TVL = vault balance + staked amount (already in FLOW terms)
        return self.getVaultBalance() + self.totalStaked
    }
    
    init(evmStakingPoolAddressHex: String) {
        // Initialize constants
        self.minimumDeposit = 1.0  // 1 FLOW minimum to prevent dust/sybil attacks
        
        // Initialize paths
        self.DepositReceiverStoragePath = /storage/PrizeVaultV3DepositReceiver
        self.DepositReceiverPublicPath = /public/PrizeVaultV3DepositReceiver
        self.VaultStoragePath = /storage/PrizeVaultV3MainVault
        self.AdminStoragePath = /storage/PrizeVaultV3Admin
        self.PrizeDrawReceiptStoragePath = /storage/PrizeVaultV3DrawReceipt
        
        // Initialize state
        self.totalDeposited = 0.0
        self.totalStaked = 0.0
        self.totalRewardsHarvested = 0.0
        self.totalPrizesDistributed = 0.0
        self.prizeRound = 0
        self.lastDrawBlock = 0  // Allow first draw immediately (0 means never drawn before)
        self.blocksPerMonth = 2592000  // ~30 days at 1 second per block on Flow
        self.monthlyDrawReceipt <- nil
        self.totalPendingWithdrawalInCOA = 0.0  // No pending withdrawals initially
        self.userDeposits = {}
        self.userPrizes = {}
        self.pendingWithdrawals = {}
        self.prizeHistory = {}
        
        // Set EVM contract addresses
        self.evmStakingPoolAddress = EVM.addressFromString(evmStakingPoolAddressHex)
        
        // ankrFLOWEVM token address on Flow EVM
        self.ankrFlowTokenAddress = EVM.addressFromString("1b97100eA1D7126C4d60027e231EA4CB25314bdb")
        
        // Ankr ratio feed address on Flow EVM
        self.ankrRatioFeedAddress = EVM.addressFromString("32015e1Bd4bAAC9b959b100B0ca253BD131dE38F")
        
        // Create the main vault to hold all deposits
        self.vault <- FlowToken.createEmptyVault(vaultType: Type<@FlowToken.Vault>()) as! @FlowToken.Vault
        
        // Create COA for EVM interactions
        self.coa <- EVM.createCadenceOwnedAccount()
        
        // Initialize RandomConsumer for commit-reveal randomness
        self.consumer <- RandomConsumer.createConsumer()
        
        // Create and save Admin resource
        self.account.storage.save(<- create Admin(), to: self.AdminStoragePath)
    }
}

