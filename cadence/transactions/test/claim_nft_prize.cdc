import "NonFungibleToken"
import "MockNFT"
import "PrizeLinkedAccounts"

/// Claim a pending NFT prize as a user
transaction(poolID: UInt64, nftIndex: Int) {
    let collection: auth(PrizeLinkedAccounts.PositionOps) &PrizeLinkedAccounts.PoolPositionCollection
    let nftCollection: &{NonFungibleToken.CollectionPublic}

    prepare(signer: auth(Storage) &Account) {
        self.collection = signer.storage.borrow<auth(PrizeLinkedAccounts.PositionOps) &PrizeLinkedAccounts.PoolPositionCollection>(
            from: PrizeLinkedAccounts.PoolPositionCollectionStoragePath
        ) ?? panic("Could not borrow PoolPositionCollection")

        // Get or create NFT collection
        if signer.storage.borrow<&MockNFT.Collection>(from: MockNFT.CollectionStoragePath) == nil {
            let collection <- MockNFT.createEmptyCollection(nftType: Type<@MockNFT.NFT>())
            signer.storage.save(<-collection, to: MockNFT.CollectionStoragePath)
        }

        self.nftCollection = signer.storage.borrow<&{NonFungibleToken.CollectionPublic}>(
            from: MockNFT.CollectionStoragePath
        ) ?? panic("Could not borrow NFT collection")
    }

    execute {
        let nft <- self.collection.claimPendingNFT(poolID: poolID, nftIndex: nftIndex)
        self.nftCollection.deposit(token: <- nft)
        log("Claimed NFT prize from pool ".concat(poolID.toString()))
    }
}
