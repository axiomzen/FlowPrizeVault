import PrizeLinkedAccounts from "../../contracts/PrizeLinkedAccounts.cdc"
import FungibleToken from "FungibleToken"

/// Deposit transaction - Deposits tokens into a specific PrizeLinkedAccounts pool
/// Works with any FungibleToken vault (FLOW, pyUSD, etc.)
/// Auto-registers with the pool on first deposit
///
/// Parameters:
/// - poolID: The ID of the pool to deposit into
/// - amount: The amount of tokens to deposit
/// - maxSlippageBps: Maximum acceptable slippage in basis points (100 = 1%, 10000 = no protection)
/// - vaultPath: Storage path identifier for the token vault (e.g., "flowTokenVault", "EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750Vault")
transaction(poolID: UInt64, amount: UFix64, maxSlippageBps: UInt64, vaultPath: String) {

    let collectionRef: auth(PrizeLinkedAccounts.PositionOps) &PrizeLinkedAccounts.PoolPositionCollection
    let vaultRef: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}

    prepare(signer: auth(Storage) &Account) {
        // Borrow the collection with PositionOps entitlement for deposit
        self.collectionRef = signer.storage.borrow<auth(PrizeLinkedAccounts.PositionOps) &PrizeLinkedAccounts.PoolPositionCollection>(
            from: PrizeLinkedAccounts.PoolPositionCollectionStoragePath
        ) ?? panic("No PoolPositionCollection found. Run setup_collection.cdc first")

        // Build the storage path from the identifier and borrow the vault
        let storagePath = StoragePath(identifier: vaultPath)
            ?? panic("Invalid storage path identifier: ".concat(vaultPath))

        self.vaultRef = signer.storage.borrow<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(
            from: storagePath
        ) ?? panic("Could not borrow FungibleToken vault at /storage/".concat(vaultPath))
    }

    execute {
        // Withdraw tokens from vault
        let tokens <- self.vaultRef.withdraw(amount: amount)

        // Deposit into the pool (auto-registers if first time)
        self.collectionRef.deposit(poolID: poolID, from: <-tokens, maxSlippageBps: maxSlippageBps)

        log("Successfully deposited ".concat(amount.toString()).concat(" tokens into pool ").concat(poolID.toString()))
    }
}
