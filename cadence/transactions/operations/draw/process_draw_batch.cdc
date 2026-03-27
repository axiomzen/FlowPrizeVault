import "PrizeLinkedAccounts"

/// Process Draw Batch — Phase 2 of the draw cycle (permissionless).
///
/// Finalizes each user's TWAB weight and appends it to the cumulative weight array
/// used for weighted winner selection. Repeat until complete.
///
/// Check progress with get_draw_status.cdc (batchProgress field).
/// Lower the limit if transactions approach computation limits (500 is safe for most pools).
///
/// This transaction requires NO special entitlements — any account can call it.
///
/// Parameters:
///   poolID — the pool to process
///   limit  — max users to process per call (recommended: 500)
transaction(poolID: UInt64, limit: Int) {

    execute {
        let remaining = PrizeLinkedAccounts.processDrawBatch(poolID: poolID, limit: limit)

        if remaining > 0 {
            log("Batch processed. Remaining: ".concat(remaining.toString()).concat(" — call again to continue"))
        } else {
            log("All batches complete for pool ".concat(poolID.toString()).concat(" — ready for complete_draw.cdc"))
        }
    }
}
