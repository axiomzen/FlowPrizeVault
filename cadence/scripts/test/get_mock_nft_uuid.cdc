import "NonFungibleToken"
import "MockNFT"

/// Get the uuid of a MockNFT by its id
access(all) fun main(ownerAddress: Address, nftID: UInt64): UInt64 {
    let account = getAccount(ownerAddress)

    let collectionRef = account
        .capabilities.borrow<&MockNFT.Collection>(MockNFT.CollectionPublicPath)
        ?? panic("Could not borrow MockNFT collection")

    let nftRef = collectionRef.borrowNFT(nftID)
        ?? panic("NFT not found in collection")

    return nftRef.uuid
}
