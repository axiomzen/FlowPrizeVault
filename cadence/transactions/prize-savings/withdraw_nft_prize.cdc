import PrizeSavings from "../../contracts/PrizeSavings.cdc"
import NonFungibleToken from "NonFungibleToken"

/// Admin transaction to withdraw an unclaimed NFT prize from the pool
/// This allows the admin to recover NFTs that haven't been claimed
///
/// Parameters:
/// - poolID: The pool ID
/// - nftID: The specific NFT ID to withdraw
/// - nftReceiverPath: Storage path where NFTs should be deposited
transaction(poolID: UInt64, nftID: UInt64, nftReceiverPath: StoragePath) {
    let adminRef: auth(PrizeSavings.ConfigOps) &PrizeSavings.Admin
    let nftReceiverRef: &{NonFungibleToken.CollectionPublic}
    
    prepare(signer: auth(Storage) &Account) {
        // Borrow admin resource
        self.adminRef = signer.storage.borrow<auth(PrizeSavings.ConfigOps) &PrizeSavings.Admin>(
            from: PrizeSavings.AdminStoragePath
        ) ?? panic("Could not borrow Admin resource")
        
        // Borrow NFT receiver
        self.nftReceiverRef = signer.storage.borrow<&{NonFungibleToken.CollectionPublic}>(
            from: nftReceiverPath
        ) ?? panic("NFT collection not found at specified path")
    }
    
    execute {
        // Withdraw the NFT from the pool
        let nft <- self.adminRef.withdrawNFTPrize(
            poolID: poolID,
            nftID: nftID
        )
        
        let withdrawnNFTID = nft.uuid
        
        // Deposit to admin's collection
        self.nftReceiverRef.deposit(token: <- nft)
        
        log("Admin withdrew NFT prize with ID: ".concat(withdrawnNFTID.toString()))
    }
}

