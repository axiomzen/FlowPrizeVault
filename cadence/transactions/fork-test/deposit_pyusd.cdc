import "PrizeLinkedAccounts"
import "FungibleToken"

/// Fork-test: Deposit pyUSD into a PrizeLinkedAccounts pool.
/// Uses string imports so they resolve via mainnet-fork aliases.
///
/// Parameters:
/// - poolID: The ID of the pool to deposit into
/// - amount: The amount of pyUSD to deposit
/// - maxSlippageBps: Maximum acceptable slippage in basis points (100 = 1%, 10000 = no protection)
transaction(poolID: UInt64, amount: UFix64, maxSlippageBps: UInt64) {

    let collectionRef: auth(PrizeLinkedAccounts.PositionOps) &PrizeLinkedAccounts.PoolPositionCollection
    let vaultRef: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}

    prepare(signer: auth(Storage) &Account) {
        // Borrow the collection with PositionOps entitlement for deposit
        self.collectionRef = signer.storage.borrow<auth(PrizeLinkedAccounts.PositionOps) &PrizeLinkedAccounts.PoolPositionCollection>(
            from: PrizeLinkedAccounts.PoolPositionCollectionStoragePath
        ) ?? panic("No PoolPositionCollection found. Run setup_collection.cdc first")

        // Borrow the pyUSD vault to withdraw from
        let pyusdVaultPath = StoragePath(identifier: "EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750Vault")
            ?? panic("Invalid pyUSD vault path")

        self.vaultRef = signer.storage.borrow<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(
            from: pyusdVaultPath
        ) ?? panic("Could not borrow pyUSD vault")
    }

    execute {
        // Withdraw tokens from vault
        let tokens <- self.vaultRef.withdraw(amount: amount)

        // Deposit into the pool (auto-registers if first time)
        self.collectionRef.deposit(poolID: poolID, from: <-tokens, maxSlippageBps: maxSlippageBps)

        log("Successfully deposited ".concat(amount.toString()).concat(" pyUSD into pool ").concat(poolID.toString()))
    }
}
