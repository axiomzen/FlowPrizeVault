import "PrizeLinkedAccounts"
import "FungibleToken"
import "FlowToken"

/// Deposit tokens into a PrizeLinkedAccounts pool with configurable slippage protection
/// Unlike deposit_to_pool.cdc which hardcodes maxSlippageBps=10000, this allows testing
/// slippage protection rejection.
///
/// Parameters:
/// - poolID: The pool to deposit into
/// - amount: Amount of FLOW tokens to deposit
/// - maxSlippageBps: Maximum acceptable slippage in basis points (100 = 1%, 10000 = no protection)
transaction(poolID: UInt64, amount: UFix64, maxSlippageBps: UInt64) {

    let collectionRef: auth(PrizeLinkedAccounts.PositionOps) &PrizeLinkedAccounts.PoolPositionCollection
    let vaultRef: auth(FungibleToken.Withdraw) &FlowToken.Vault

    prepare(signer: auth(Storage) &Account) {
        self.collectionRef = signer.storage.borrow<auth(PrizeLinkedAccounts.PositionOps) &PrizeLinkedAccounts.PoolPositionCollection>(
            from: PrizeLinkedAccounts.PoolPositionCollectionStoragePath
        ) ?? panic("No PoolPositionCollection found. Run setup_user_collection.cdc first")

        self.vaultRef = signer.storage.borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(
            from: /storage/flowTokenVault
        ) ?? panic("Could not borrow FlowToken vault")
    }

    execute {
        let tokens <- self.vaultRef.withdraw(amount: amount)
        self.collectionRef.deposit(poolID: poolID, from: <-tokens, maxSlippageBps: maxSlippageBps)

        log("Deposited ".concat(amount.toString()).concat(" with maxSlippageBps=").concat(maxSlippageBps.toString()))
    }
}
