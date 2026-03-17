import FungibleToken from 0xf233dcee88fe0abe
import FungibleTokenMetadataViews from 0xf233dcee88fe0abe
import PrizeLinkedAccounts from 0xa092c4aab33daeda

/// Withdraw tokens from PrizeLinkedAccounts pool (Prize-Linked Account)
///
/// @param poolID: The PrizeLinkedAccounts pool ID to withdraw from
/// @param vaultIdentifier: Token vault type identifier (e.g., USDF)
/// @param amount: Amount to withdraw
///
transaction(
    poolID: UInt64,
    vaultIdentifier: String,
    amount: UFix64
) {
    let destinationVaultRef: &{FungibleToken.Vault}
    let collectionRef: auth(PrizeLinkedAccounts.PositionOps) &PrizeLinkedAccounts.PoolPositionCollection
    let initialDestinationBalance: UFix64
    let initialPoolBalance: UFix64

    prepare(signer: auth(BorrowValue) &Account) {
        // Resolve vault metadata
        let vaultType = CompositeType(vaultIdentifier)
            ?? panic("Invalid vaultIdentifier \(vaultIdentifier)")
        let tokenContract = getAccount(vaultType.address!).contracts.borrow<&{FungibleToken}>(name: vaultType.contractName!)
            ?? panic("Vault type \(vaultIdentifier) is not defined by a FungibleToken contract")
        let vaultData = tokenContract.resolveContractView(
            resourceType: vaultType,
            viewType: Type<FungibleTokenMetadataViews.FTVaultData>()
        ) as? FungibleTokenMetadataViews.FTVaultData
            ?? panic("Could not resolve FTVaultData for vault type \(vaultIdentifier)")

    // Borrow destination vault and capture initial balance
        self.destinationVaultRef = signer.storage.borrow<&{FungibleToken.Vault}>(from: vaultData.storagePath)
            ?? panic("Vault of type \(vaultIdentifier) not found at \(vaultData.storagePath)")
        self.initialDestinationBalance = self.destinationVaultRef.balance

        // Borrow collection reference with PositionOps entitlement for withdraw
        self.collectionRef = signer.storage.borrow<auth(PrizeLinkedAccounts.PositionOps) &PrizeLinkedAccounts.PoolPositionCollection>(from: PrizeLinkedAccounts.PoolPositionCollectionStoragePath)
            ?? panic("PoolPositionCollection not found at \(PrizeLinkedAccounts.PoolPositionCollectionStoragePath)")

        // Verify user is registered with pool and capture initial balance
        if !self.collectionRef.isRegisteredWithPool(poolID: poolID) {
            panic("Not registered with pool \(poolID) - no position to withdraw from")
        }
        self.initialPoolBalance = PrizeLinkedAccounts.getProjectedUserBalance(poolID: poolID, receiverID: self.collectionRef.getReceiverID())
    }

    pre {
        amount > 0.0: "Amount must be greater than zero"
        amount <= self.initialPoolBalance: "Insufficient pool balance - requested \(amount), \(self.initialPoolBalance) available"
    }

    execute {
        // Withdraw from PrizeLinkedAccounts pool and deposit to destination vault
        let withdrawnVault <- self.collectionRef.withdraw(poolID: poolID, amount: amount)
        self.destinationVaultRef.deposit(from: <- withdrawnVault)
    }

    post {
        // Ensure at least 95% of amount was received (allows slippage from yield source)
        self.destinationVaultRef.balance >= self.initialDestinationBalance + (amount * 0.95):
            "Insufficient funds received - expected at least \(amount * 0.95), got \(self.destinationVaultRef.balance - self.initialDestinationBalance)"
    }
}
