import "NonFungibleToken"
import "MockNFT"
import "PrizeLinkedAccounts"

/// Deposit an NFT prize to a pool (admin operation)
transaction(poolID: UInt64, nftID: UInt64) {
    let admin: auth(PrizeLinkedAccounts.ConfigOps) &PrizeLinkedAccounts.Admin
    let nft: @{NonFungibleToken.NFT}

    prepare(signer: auth(Storage) &Account) {
        self.admin = signer.storage.borrow<auth(PrizeLinkedAccounts.ConfigOps) &PrizeLinkedAccounts.Admin>(
            from: PrizeLinkedAccounts.AdminStoragePath
        ) ?? panic("Could not borrow Admin reference")

        // Withdraw NFT from signer's collection
        let collection = signer.storage.borrow<auth(NonFungibleToken.Withdraw) &MockNFT.Collection>(
            from: MockNFT.CollectionStoragePath
        ) ?? panic("Could not borrow MockNFT collection")

        self.nft <- collection.withdraw(withdrawID: nftID)
    }

    execute {
        self.admin.depositNFTPrize(poolID: poolID, nft: <- self.nft)
        log("Deposited NFT prize to pool ".concat(poolID.toString()))
    }
}
