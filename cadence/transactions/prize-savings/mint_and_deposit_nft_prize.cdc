import PrizeSavings from "../../contracts/PrizeSavings.cdc"
import SimpleNFT from "../../contracts/SimpleNFT.cdc"
import NonFungibleToken from "NonFungibleToken"

/// Mint a SimpleNFT and deposit it as an NFT prize for the lottery
///
/// Parameters:
/// - poolID: The pool to add the NFT prize to
/// - nftName: Name for the NFT
/// - nftDescription: Description for the NFT
transaction(poolID: UInt64, nftName: String, nftDescription: String) {
    let adminRef: auth(PrizeSavings.ConfigOps) &PrizeSavings.Admin
    let minterRef: &SimpleNFT.NFTMinter
    let collectionRef: auth(NonFungibleToken.Withdraw) &SimpleNFT.Collection
    let signerAddress: Address
    
    prepare(signer: auth(Storage, Capabilities) &Account) {
        // Borrow admin reference
        self.adminRef = signer.storage.borrow<auth(PrizeSavings.ConfigOps) &PrizeSavings.Admin>(
            from: PrizeSavings.AdminStoragePath
        ) ?? panic("Admin resource not found")
        
        // Borrow minter reference
        self.minterRef = signer.storage.borrow<&SimpleNFT.NFTMinter>(
            from: SimpleNFT.MinterStoragePath
        ) ?? panic("NFTMinter not found - deploy SimpleNFT contract first")
        
        self.signerAddress = signer.address
        
        // Ensure we have an NFT collection
        if signer.storage.borrow<&SimpleNFT.Collection>(from: SimpleNFT.CollectionStoragePath) == nil {
            let collection <- SimpleNFT.createEmptyCollection(nftType: Type<@SimpleNFT.NFT>())
            signer.storage.save(<-collection, to: SimpleNFT.CollectionStoragePath)
            
            let cap = signer.capabilities.storage.issue<&{NonFungibleToken.CollectionPublic, SimpleNFT.SimpleNFTCollectionPublic}>(
                SimpleNFT.CollectionStoragePath
            )
            signer.capabilities.publish(cap, at: SimpleNFT.CollectionPublicPath)
        }
        
        // Borrow with Withdraw entitlement to allow withdrawing NFT
        self.collectionRef = signer.storage.borrow<auth(NonFungibleToken.Withdraw) &SimpleNFT.Collection>(
            from: SimpleNFT.CollectionStoragePath
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

