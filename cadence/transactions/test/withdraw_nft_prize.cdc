import "NonFungibleToken"
import "MockNFT"
import "PrizeLinkedAccounts"

/// Withdraw an unassigned NFT prize from a pool (admin operation)
transaction(poolID: UInt64, nftID: UInt64) {
    let admin: auth(PrizeLinkedAccounts.ConfigOps) &PrizeLinkedAccounts.Admin
    let collectionRef: &{NonFungibleToken.CollectionPublic}

    prepare(signer: auth(Storage) &Account) {
        self.admin = signer.storage.borrow<auth(PrizeLinkedAccounts.ConfigOps) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) ?? panic("Could not borrow Admin reference")

        // Get collection to receive the withdrawn NFT
        self.collectionRef = signer.storage.borrow<&{NonFungibleToken.CollectionPublic}>(
            from: MockNFT.CollectionStoragePath
        ) ?? panic("Could not borrow MockNFT collection")
    }

    execute {
        let nft <- self.admin.withdrawNFTPrize(poolID: poolID, nftID: nftID)
        self.collectionRef.deposit(token: <- nft)
        log("Withdrew NFT prize from pool ".concat(poolID.toString()))
    }
}
