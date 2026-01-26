import "NonFungibleToken"
import "MockNFT"

/// Mint a MockNFT to a recipient
transaction(recipientAddress: Address, name: String, description: String) {
    let minter: &MockNFT.NFTMinter
    let recipientRef: &{NonFungibleToken.CollectionPublic}

    prepare(signer: auth(BorrowValue) &Account) {
        self.minter = signer.storage.borrow<&MockNFT.NFTMinter>(from: MockNFT.MinterStoragePath)
            ?? panic("Could not borrow MockNFT minter reference")

        self.recipientRef = getAccount(recipientAddress)
            .capabilities.borrow<&{NonFungibleToken.CollectionPublic}>(MockNFT.CollectionPublicPath)
            ?? panic("Could not borrow recipient collection reference")
    }

    execute {
        let nftID = self.minter.mintNFT(
            recipient: self.recipientRef,
            name: name,
            description: description,
            thumbnail: "https://example.com/thumbnail.png"
        )
        log("Minted NFT with ID: ".concat(nftID.toString()))
    }
}
