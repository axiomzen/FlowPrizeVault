import "NonFungibleToken"
import "MockNFT"

/// Setup a MockNFT collection for a user
transaction {
    prepare(signer: auth(Storage, Capabilities) &Account) {
        // Check if collection already exists
        if signer.storage.borrow<&MockNFT.Collection>(from: MockNFT.CollectionStoragePath) == nil {
            // Create and save collection
            let collection <- MockNFT.createEmptyCollection(nftType: Type<@MockNFT.NFT>())
            signer.storage.save(<-collection, to: MockNFT.CollectionStoragePath)

            // Create public capability
            let cap = signer.capabilities.storage.issue<&{NonFungibleToken.CollectionPublic, MockNFT.MockNFTCollectionPublic}>(MockNFT.CollectionStoragePath)
            signer.capabilities.publish(cap, at: MockNFT.CollectionPublicPath)
        }
    }
}
