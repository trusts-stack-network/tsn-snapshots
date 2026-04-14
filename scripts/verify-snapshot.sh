#!/bin/bash
# TSN Snapshot Verification Script
# Usage: ./verify-snapshot.sh <manifest.json> <snapshot.json.gz>
#
# Verifies:
# 1. Producer Ed25519 signature
# 2. SHA256 of snapshot file
# 3. Seed confirmations (at least 2 required)
#
# Dependencies: python3, jq (optional for pretty output)

set -euo pipefail

MANIFEST="${1:?Usage: $0 <manifest.json> <snapshot.json.gz>}"
SNAPSHOT="${2:?Usage: $0 <manifest.json> <snapshot.json.gz>}"
KEYS_DIR="$(dirname "$0")/../public-keys"
MIN_CONFIRMATIONS=2

echo "=== TSN Snapshot Verification ==="
echo ""

# Check files exist
[ -f "$MANIFEST" ] || { echo "ERROR: Manifest not found: $MANIFEST"; exit 1; }
[ -f "$SNAPSHOT" ] || { echo "ERROR: Snapshot not found: $SNAPSHOT"; exit 1; }

# Extract manifest fields
HEIGHT=$(python3 -c "import json; m=json.load(open('$MANIFEST')); print(m['height'])")
BLOCK_HASH=$(python3 -c "import json; m=json.load(open('$MANIFEST')); print(m['block_hash'])")
EXPECTED_SHA=$(python3 -c "import json; m=json.load(open('$MANIFEST')); print(m['snapshot_sha256'])")
PRODUCER=$(python3 -c "import json; m=json.load(open('$MANIFEST')); print(m['producer']['seed_name'])")
PRODUCER_PK=$(python3 -c "import json; m=json.load(open('$MANIFEST')); print(m['producer']['public_key'])")
SIGNATURE=$(python3 -c "import json; m=json.load(open('$MANIFEST')); print(m['signature'])")
STATE_ROOT=$(python3 -c "import json; m=json.load(open('$MANIFEST')); print(m['state_root'])")
SIZE=$(python3 -c "import json; m=json.load(open('$MANIFEST')); print(m['snapshot_size_bytes'])")

echo "Snapshot height:  $HEIGHT"
echo "Block hash:       ${BLOCK_HASH:0:32}..."
echo "State root:       ${STATE_ROOT:0:32}..."
echo "Producer:         $PRODUCER"
echo "Producer pubkey:  ${PRODUCER_PK:0:32}..."
echo "File size:        $SIZE bytes"
echo ""

# 1. Verify SHA256
echo "--- SHA256 Verification ---"
ACTUAL_SHA=$(sha256sum "$SNAPSHOT" | awk '{print $1}')
if [ "$ACTUAL_SHA" = "$EXPECTED_SHA" ]; then
    echo "PASS: SHA256 matches ($ACTUAL_SHA)"
else
    echo "FAIL: SHA256 mismatch"
    echo "  Expected: $EXPECTED_SHA"
    echo "  Actual:   $ACTUAL_SHA"
    exit 1
fi
echo ""

# 2. Verify producer signature
echo "--- Producer Signature ---"
SIGCHECK=$(python3 -c "
import json, hashlib
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

m = json.load(open('$MANIFEST'))
# Reconstruct signing payload (deterministic JSON without signature/confirmations)
payload = json.dumps({
    'version': m['version'],
    'chain_id': m['chain_id'],
    'height': m['height'],
    'block_hash': m['block_hash'],
    'state_root': m['state_root'],
    'snapshot_sha256': m['snapshot_sha256'],
    'snapshot_size_bytes': m['snapshot_size_bytes'],
    'format': m['format'],
    'binary_version': m['binary_version'],
    'created_at': m['created_at'],
    'producer': {
        'seed_name': m['producer']['seed_name'],
        'peer_id': m['producer']['peer_id'],
        'public_key': m['producer']['public_key'],
    }
}).encode()

pk_bytes = bytes.fromhex(m['producer']['public_key'])
sig_bytes = bytes.fromhex(m['signature'])
pk = Ed25519PublicKey.from_public_bytes(pk_bytes)
try:
    pk.verify(sig_bytes, payload)
    print('PASS')
except Exception as e:
    print(f'FAIL: {e}')
" 2>&1)

if [ "$SIGCHECK" = "PASS" ]; then
    echo "PASS: Producer signature valid"
else
    echo "FAIL: $SIGCHECK"
    exit 1
fi
echo ""

# 3. Verify seed confirmations
echo "--- Seed Confirmations ---"
VALID_COUNT=$(python3 -c "
import json
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

m = json.load(open('$MANIFEST'))
valid = 0
for c in m.get('confirmations', []):
    if not c.get('block_hash_match') or not c.get('state_root_match'):
        print(f'  SKIP {c[\"seed_name\"]}: hash/state mismatch')
        continue
    payload = json.dumps({
        'seed_name': c['seed_name'],
        'height': c['height'],
        'block_hash_match': c['block_hash_match'],
        'state_root_match': c['state_root_match'],
        'confirmed_at': c['confirmed_at'],
    }).encode()
    pk_bytes = bytes.fromhex(c['public_key'])
    sig_bytes = bytes.fromhex(c['signature'])
    pk = Ed25519PublicKey.from_public_bytes(pk_bytes)
    try:
        pk.verify(sig_bytes, payload)
        print(f'  PASS: {c[\"seed_name\"]} confirmed at {c[\"confirmed_at\"]}')
        valid += 1
    except Exception as e:
        print(f'  FAIL: {c[\"seed_name\"]}: {e}')
print(f'TOTAL:{valid}')
" 2>&1)

echo "$VALID_COUNT" | grep -v "^TOTAL:"
TOTAL=$(echo "$VALID_COUNT" | grep "^TOTAL:" | cut -d: -f2)

if [ "${TOTAL:-0}" -ge "$MIN_CONFIRMATIONS" ]; then
    echo "PASS: $TOTAL valid confirmations (minimum: $MIN_CONFIRMATIONS)"
else
    echo "FAIL: Only $TOTAL valid confirmations (minimum: $MIN_CONFIRMATIONS)"
    exit 1
fi
echo ""

echo "=== ALL CHECKS PASSED ==="
echo "Snapshot at height $HEIGHT is cryptographically verified."
echo "  - SHA256:         OK"
echo "  - Producer sig:   OK"
echo "  - Confirmations:  $TOTAL/$MIN_CONFIRMATIONS"
