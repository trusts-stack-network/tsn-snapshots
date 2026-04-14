#!/bin/bash
# TSN Snapshot Publisher — exports, signs, confirms, publishes to GitHub + seeds
# Runs on the snapshot producer node (node-1)
# Usage: ./publish-snapshot.sh
set -euo pipefail

REPO="trusts-stack-network/tsn-snapshots"
NODE_API="http://localhost:9333"
SNAPSHOT_DIR="/opt/tsn/snapshots"
RETENTION_HOURS=24

echo "=== TSN Snapshot Publisher ==="
echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo ""

# 1. Trigger export on local node
echo "[1/5] Triggering snapshot export..."
EXPORT_RESULT=$(curl -sf -X POST "$NODE_API/snapshot/export" 2>/dev/null) || {
    echo "ERROR: Snapshot export failed (node might not be ready)"
    exit 1
}

HEIGHT=$(echo "$EXPORT_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['height'])")
echo "  Exported at height $HEIGHT"

# 2. Wait for async confirmations to arrive
echo "[2/5] Waiting for seed confirmations (15s)..."
sleep 15

# 3. Fetch the manifest with accumulated confirmations
echo "[3/5] Fetching signed manifest..."
MANIFEST=$(curl -sf "$NODE_API/snapshot/latest") || {
    echo "ERROR: Failed to fetch manifest"
    exit 1
}

CONFS=$(echo "$MANIFEST" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('confirmations',[])))")
echo "  Got $CONFS confirmations"

if [ "$CONFS" -lt 2 ]; then
    echo "ERROR: Need at least 2 confirmations, got $CONFS"
    exit 1
fi

# 4. Download the snapshot file from the node
echo "[4/5] Downloading snapshot file..."
mkdir -p "$SNAPSHOT_DIR"
SNAP_FILE="$SNAPSHOT_DIR/snapshot-${HEIGHT}.json.gz"
MANIFEST_FILE="$SNAPSHOT_DIR/manifest-${HEIGHT}.json"

curl -sf "$NODE_API/snapshot/download" -o "$SNAP_FILE" || {
    echo "ERROR: Failed to download snapshot"
    exit 1
}

echo "$MANIFEST" | python3 -m json.tool > "$MANIFEST_FILE"

# Verify SHA256 before publishing
EXPECTED_SHA=$(echo "$MANIFEST" | python3 -c "import sys,json; print(json.load(sys.stdin)['snapshot_sha256'])")
ACTUAL_SHA=$(sha256sum "$SNAP_FILE" | awk '{print $1}')
if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
    echo "ERROR: SHA256 mismatch — snapshot corrupted"
    echo "  Expected: $EXPECTED_SHA"
    echo "  Actual:   $ACTUAL_SHA"
    rm -f "$SNAP_FILE" "$MANIFEST_FILE"
    exit 1
fi
echo "  SHA256 verified: ${ACTUAL_SHA:0:16}..."

SNAP_SIZE=$(du -h "$SNAP_FILE" | awk '{print $1}')
echo "  Snapshot: $SNAP_SIZE, Manifest: $(wc -c < "$MANIFEST_FILE") bytes"

# 5. Publish to GitHub as a release
echo "[5/5] Publishing to GitHub..."
TAG="snapshot-${HEIGHT}"
TITLE="Snapshot at height ${HEIGHT}"
BODY="## TSN State Snapshot

- **Height**: ${HEIGHT}
- **Confirmations**: ${CONFS} seed(s)
- **SHA256**: \`${ACTUAL_SHA}\`
- **Size**: ${SNAP_SIZE}
- **Created**: $(date -u '+%Y-%m-%dT%H:%M:%SZ')

Verify with: \`./scripts/verify-snapshot.sh manifest-${HEIGHT}.json snapshot-${HEIGHT}.json.gz\`"

# Create release with assets
gh release create "$TAG" \
    --repo "$REPO" \
    --title "$TITLE" \
    --notes "$BODY" \
    "$SNAP_FILE" \
    "$MANIFEST_FILE" \
    2>/dev/null || {
    echo "ERROR: GitHub release creation failed"
    exit 1
}

echo ""
echo "=== Published to GitHub ==="
echo "  GitHub: https://github.com/$REPO/releases/tag/$TAG"
echo "  Height: $HEIGHT"
echo "  Confirmations: $CONFS"
echo "  SHA256: $ACTUAL_SHA"

# 6. Replicate to all seed nodes
echo ""
echo "[6/7] Replicating to seed nodes..."
SSH_KEY="/root/tsn-team/ssh_keys/tsn_ed25519"
SEEDS="45.145.165.223 151.240.19.253 45.145.164.76 146.19.168.71 45.132.96.141"
for IP in $SEEDS; do
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no root@$IP "mkdir -p /opt/tsn/snapshots" 2>/dev/null
    scp -i "$SSH_KEY" -o StrictHostKeyChecking=no \
        "$SNAP_FILE" "$MANIFEST_FILE" \
        root@$IP:/opt/tsn/snapshots/ 2>/dev/null && echo "  $IP: OK" || echo "  $IP: FAILED"
done

# 7. Safe purge — only remove old snapshots, never the last one
echo ""
echo "[7/7] Purging old snapshots (rolling 24h, never delete last)..."
SCRIPT_DIR="$(dirname "$0")"
if [ -x "$SCRIPT_DIR/purge-old-snapshots.sh" ]; then
    "$SCRIPT_DIR/purge-old-snapshots.sh"
else
    echo "  Purge script not found — skipping"
fi

# Also purge on each seed
for IP in $SEEDS; do
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no root@$IP "
        SNAP_DIR=/opt/tsn/snapshots
        NOW=\$(date +%s)
        RETENTION=86400
        SNAP_COUNT=\$(ls \$SNAP_DIR/snapshot-*.json.gz 2>/dev/null | wc -l)
        if [ \"\$SNAP_COUNT\" -le 1 ]; then
            echo '  $IP: only 1 snapshot, keeping'
        else
            NEWEST=\$(ls -t \$SNAP_DIR/snapshot-*.json.gz | head -1)
            for f in \$SNAP_DIR/snapshot-*.json.gz; do
                [ \"\$f\" = \"\$NEWEST\" ] && continue
                AGE=\$(( NOW - \$(stat -c %Y \"\$f\") ))
                if [ \"\$AGE\" -gt \"\$RETENTION\" ]; then
                    H=\$(basename \$f | sed 's/snapshot-//;s/.json.gz//')
                    rm -f \$SNAP_DIR/snapshot-\${H}.json.gz \$SNAP_DIR/manifest-\${H}.json
                    echo \"  $IP: purged snapshot-\${H} (age: \$((AGE/3600))h)\"
                fi
            done
        fi
    " 2>/dev/null
done

echo ""
echo "=== Complete ==="
echo "  Size: $SNAP_SIZE"
