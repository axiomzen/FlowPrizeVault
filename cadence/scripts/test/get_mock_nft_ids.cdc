import "NonFungibleToken"
import "MockNFT"

/// Get MockNFT IDs owned by an account
access(all) fun main(address: Address): [UInt64] {
    let account = getAccount(address)

    let collectionRef = account
        .capabilities.borrow<&{NonFungibleToken.CollectionPublic}>(MockNFT.CollectionPublicPath)

    if collectionRef == nil {
        return []
    }

    return collectionRef!.getIDs()
}
