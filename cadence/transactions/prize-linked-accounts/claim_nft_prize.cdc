import PrizeLinkedAccounts from "../../contracts/PrizeLinkedAccounts.cdc"
import NonFungibleToken from "NonFungibleToken"

/// Claim a pending NFT prize from lottery winnings
///
/// Parameters:
/// - poolID: The pool ID
/// - nftIndex: Index of the NFT to claim (0 for first pending NFT)
/// - nftReceiverPath: Storage path where NFTs should be deposited
transaction(poolID: UInt64, nftIndex: Int, nftReceiverPath: StoragePath) {
    let collectionRef: auth(PrizeLinkedAccounts.PositionOps) &PrizeLinkedAccounts.PoolPositionCollection
    let nftReceiverRef: &{NonFungibleToken.CollectionPublic}
    
    prepare(signer: auth(Storage) &Account) {
        // Borrow pool position collection with Withdraw entitlement for claiming NFTs
        self.collectionRef = signer.storage.borrow<auth(PrizeLinkedAccounts.PositionOps) &PrizeLinkedAccounts.PoolPositionCollection>(
            from: PrizeLinkedAccounts.PoolPositionCollectionStoragePath
        ) ?? panic("PoolPositionCollection not found")
        
        // Borrow NFT receiver
        self.nftReceiverRef = signer.storage.borrow<&{NonFungibleToken.CollectionPublic}>(
            from: nftReceiverPath
        ) ?? panic("NFT collection not found at specified path")
    }
    
    execute {
        // Claim the NFT from pending prizes
        let nft <- self.collectionRef.claimPendingNFT(
            poolID: poolID,
            nftIndex: nftIndex
        )
        
        let nftID = nft.uuid
        
        // Deposit to user's collection
        self.nftReceiverRef.deposit(token: <- nft)
        
        log("Claimed NFT prize with ID: ".concat(nftID.toString()))
    }
}

