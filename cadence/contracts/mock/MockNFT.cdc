import "NonFungibleToken"
import "ViewResolver"
import "MetadataViews"

/// MockNFT - A basic NFT contract for testing Prize Vault NFT prizes
/// Each NFT has a unique ID and name
access(all) contract MockNFT: NonFungibleToken {
    
    access(all) var totalSupply: UInt64
    
    access(all) event ContractInitialized()
    access(all) event Withdraw(id: UInt64, from: Address?)
    access(all) event Deposit(id: UInt64, to: Address?)
    access(all) event Minted(id: UInt64, name: String)
    
    access(all) let CollectionStoragePath: StoragePath
    access(all) let CollectionPublicPath: PublicPath
    access(all) let MinterStoragePath: StoragePath
    
    access(all) resource NFT: NonFungibleToken.NFT, ViewResolver.Resolver {
        access(all) let id: UInt64
        access(all) let name: String
        access(all) let description: String
        access(all) let thumbnail: String
        
        init(id: UInt64, name: String, description: String, thumbnail: String) {
            self.id = id
            self.name = name
            self.description = description
            self.thumbnail = thumbnail
        }
        
        access(all) view fun getViews(): [Type] {
            return [
                Type<MetadataViews.Display>()
            ]
        }
        
        access(all) fun resolveView(_ view: Type): AnyStruct? {
            switch view {
                case Type<MetadataViews.Display>():
                    return MetadataViews.Display(
                        name: self.name,
                        description: self.description,
                        thumbnail: MetadataViews.HTTPFile(url: self.thumbnail)
                    )
            }
            return nil
        }
        
        access(all) fun createEmptyCollection(): @{NonFungibleToken.Collection} {
            return <- MockNFT.createEmptyCollection(nftType: Type<@MockNFT.NFT>())
        }
    }
    
    access(all) resource interface MockNFTCollectionPublic {
        access(all) fun deposit(token: @{NonFungibleToken.NFT})
        access(all) view fun getIDs(): [UInt64]
        access(all) view fun borrowNFT(_ id: UInt64): &{NonFungibleToken.NFT}?
        access(all) fun borrowMockNFT(id: UInt64): &MockNFT.NFT? {
            post {
                (result == nil) || (result?.id == id):
                    "Cannot borrow MockNFT reference: The ID of the returned reference is incorrect"
            }
        }
    }
    
    access(all) resource Collection: MockNFTCollectionPublic, NonFungibleToken.Collection {
        access(all) var ownedNFTs: @{UInt64: {NonFungibleToken.NFT}}
        
        init() {
            self.ownedNFTs <- {}
        }
        
        access(NonFungibleToken.Withdraw) fun withdraw(withdrawID: UInt64): @{NonFungibleToken.NFT} {
            let token <- self.ownedNFTs.remove(key: withdrawID)
                ?? panic("NFT not found in collection")
            
            emit Withdraw(id: token.id, from: self.owner?.address)
            return <- token
        }
        
        access(all) fun deposit(token: @{NonFungibleToken.NFT}) {
            let token <- token as! @MockNFT.NFT
            let id = token.id
            let oldToken <- self.ownedNFTs[id] <- token
            
            emit Deposit(id: id, to: self.owner?.address)
            destroy oldToken
        }
        
        access(all) view fun getIDs(): [UInt64] {
            return self.ownedNFTs.keys
        }
        
        access(all) view fun borrowNFT(_ id: UInt64): &{NonFungibleToken.NFT}? {
            return &self.ownedNFTs[id]
        }
        
        access(all) fun borrowMockNFT(id: UInt64): &MockNFT.NFT? {
            if self.ownedNFTs[id] != nil {
                let ref = &self.ownedNFTs[id] as &{NonFungibleToken.NFT}?
                return ref as! &MockNFT.NFT?
            }
            return nil
        }
        
        access(all) view fun getSupportedNFTTypes(): {Type: Bool} {
            return {Type<@MockNFT.NFT>(): true}
        }
        
        access(all) view fun isSupportedNFTType(type: Type): Bool {
            return type == Type<@MockNFT.NFT>()
        }
        
        access(all) fun createEmptyCollection(): @{NonFungibleToken.Collection} {
            return <- MockNFT.createEmptyCollection(nftType: Type<@MockNFT.NFT>())
        }
    }
    
    access(all) fun createEmptyCollection(nftType: Type): @{NonFungibleToken.Collection} {
        return <- create Collection()
    }
    
    access(all) view fun getContractViews(resourceType: Type?): [Type] {
        return []
    }
    
    access(all) fun resolveContractView(resourceType: Type?, viewType: Type): AnyStruct? {
        return nil
    }
    
    access(all) resource NFTMinter {
        access(all) fun mintNFT(
            recipient: &{NonFungibleToken.CollectionPublic},
            name: String,
            description: String,
            thumbnail: String
        ): UInt64 {
            let nft <- create NFT(
                id: MockNFT.totalSupply,
                name: name,
                description: description,
                thumbnail: thumbnail
            )
            
            let id = nft.id
            recipient.deposit(token: <- nft)
            
            emit Minted(id: id, name: name)
            MockNFT.totalSupply = MockNFT.totalSupply + 1
            
            return id
        }
    }
    
    init() {
        self.totalSupply = 0
        
        self.CollectionStoragePath = /storage/MockNFTCollection
        self.CollectionPublicPath = /public/MockNFTCollection
        self.MinterStoragePath = /storage/MockNFTMinter
        
        // Create minter and save it
        let minter <- create NFTMinter()
        self.account.storage.save(<-minter, to: self.MinterStoragePath)
        
        emit ContractInitialized()
    }
}

