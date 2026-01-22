import PrizeLinkedAccounts from "../../contracts/PrizeLinkedAccounts.cdc"
import MockNFT from "../../contracts/mock/MockNFT.cdc"
import NonFungibleToken from "NonFungibleToken"

/// Mint a MockNFT and deposit it as an NFT prize for the prize
transaction(poolID: UInt64, nftName: String, nftDescription: String) {
    let adminRef: auth(PrizeLinkedAccounts.ConfigOps) &PrizeLinkedAccounts.Admin
    let minterRef: &MockNFT.NFTMinter
    let collectionRef: auth(NonFungibleToken.Withdraw) &MockNFT.Collection
    
    prepare(signer: auth(Storage, Capabilities) &Account) {
        self.adminRef = signer.storage.borrow<auth(PrizeLinkedAccounts.ConfigOps) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) ?? panic("Admin resource not found")
        
        self.minterRef = signer.storage.borrow<&MockNFT.NFTMinter>(
            from: MockNFT.MinterStoragePath
        ) ?? panic("NFTMinter not found - deploy MockNFT contract first")
        
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
            nft: <- nft
        )
        
        log("NFT Prize deposited with ID: ".concat(nftID.toString()))
    }
}

