import PrizeSavings from "../../contracts/PrizeSavings.cdc"
import MockNFT from "../../contracts/mock/MockNFT.cdc"
import NonFungibleToken from "NonFungibleToken"

/// Mint a MockNFT and deposit it as an NFT prize for the lottery
transaction(poolID: UInt64, nftName: String, nftDescription: String) {
    let adminRef: auth(PrizeSavings.ConfigOps) &PrizeSavings.Admin
    let minterRef: &MockNFT.NFTMinter
    let collectionRef: auth(NonFungibleToken.Withdraw) &MockNFT.Collection
    let signerAddress: Address
    
    prepare(signer: auth(Storage, Capabilities) &Account) {
        self.adminRef = signer.storage.borrow<auth(PrizeSavings.ConfigOps) &PrizeSavings.Admin>(
            from: PrizeSavings.AdminStoragePath
        ) ?? panic("Admin resource not found")
        
        self.minterRef = signer.storage.borrow<&MockNFT.NFTMinter>(
            from: MockNFT.MinterStoragePath
        ) ?? panic("NFTMinter not found - deploy MockNFT contract first")
        
        self.signerAddress = signer.address
        
        if signer.storage.type(at: MockNFT.CollectionStoragePath) == nil {
            let collection <- MockNFT.createEmptyCollection(nftType: Type<@MockNFT.NFT>())
            signer.storage.save(<-collection, to: MockNFT.CollectionStoragePath)
            
            let cap = signer.capabilities.storage.issue<&MockNFT.Collection>(
                MockNFT.CollectionStoragePath
            )
            signer.capabilities.publish(cap, at: MockNFT.CollectionPublicPath)
        }
        
        self.collectionRef = signer.storage.borrow<auth(NonFungibleToken.Withdraw) &MockNFT.Collection>(
            from: MockNFT.CollectionStoragePath
        ) ?? panic("Could not borrow collection reference")
    }
    
    execute {
        // Mint NFT to our collection first
        let nftID = self.minterRef.mintNFT(
            recipient: self.collectionRef,
            name: nftName,
            description: nftDescription,
            thumbnail: "https://example.com/prize-nft.png"
        )
        
        // Withdraw the NFT from collection (requires Withdraw entitlement)
        let nft <- self.collectionRef.withdraw(withdrawID: nftID)
        
        // Deposit as prize via admin
        self.adminRef.depositNFTPrize(
            poolID: poolID,
            nft: <- nft,
            depositedBy: self.signerAddress
        )
        
        log("NFT Prize deposited with ID: ".concat(nftID.toString()))
    }
}

