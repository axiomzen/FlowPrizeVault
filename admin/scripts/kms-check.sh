#!/usr/bin/env bash
# Verify the mainnet-deployer key signs through Google Cloud KMS.
# Builds a no-op transaction and signs it locally. Nothing is broadcast.
set -euo pipefail
cd "$(dirname "$0")/../.."

TX=cadence/transactions/admin/noop.cdc
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

echo "--- building (read-only) ---"
flow transactions build "$TX" \
  --proposer mainnet-deployer --authorizer mainnet-deployer --payer mainnet-deployer \
  --network mainnet --filter payload --save "$OUT/noop.rlp" --skip-version-check -y

echo "--- signing via KMS (not broadcast) ---"
flow transactions sign "$OUT/noop.rlp" \
  --signer mainnet-deployer --network mainnet \
  --filter payload --save "$OUT/noop.signed.rlp" --skip-version-check -y

echo
if [ -s "$OUT/noop.signed.rlp" ]; then
  echo "PASS: KMS produced a signature ($(wc -c < "$OUT/noop.signed.rlp") bytes). Nothing sent to mainnet."
else
  echo "FAIL: no signed payload produced."
  exit 1
fi
