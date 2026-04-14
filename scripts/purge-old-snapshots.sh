#!/bin/bash
# TSN Snapshot Purge — safe rolling retention
#
# RULE: Never delete the last snapshot. Only delete old ones AFTER a new
# one has been successfully published. Guarantees 24h+ coverage at all times.
#
# Called by publish-snapshot.sh after each successful publication.
# Usage: ./purge-old-snapshots.sh [--github] [--local]
set -euo pipefail

REPO="trusts-stack-network/tsn-snapshots"
SNAPSHOT_DIR="/opt/tsn/snapshots"
RETENTION_SECS=$((24 * 3600))
NOW=$(date +%s)

PURGE_GITHUB=false
PURGE_LOCAL=false

for arg in "$@"; do
    case "$arg" in
        --github) PURGE_GITHUB=true ;;
        --local)  PURGE_LOCAL=true ;;
        *)        echo "Usage: $0 [--github] [--local]"; exit 1 ;;
    esac
done

# Default: both
if ! $PURGE_GITHUB && ! $PURGE_LOCAL; then
    PURGE_GITHUB=true
    PURGE_LOCAL=true
fi

echo "=== TSN Snapshot Purge (rolling 24h, never delete last) ==="
echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# ---- Local purge ----
if $PURGE_LOCAL; then
    echo ""
    echo "--- Local purge ($SNAPSHOT_DIR) ---"
    if [ -d "$SNAPSHOT_DIR" ]; then
        # Count snapshot files (each snapshot = 1 .json.gz + 1 .json manifest)
        SNAP_COUNT=$(ls "$SNAPSHOT_DIR"/snapshot-*.json.gz 2>/dev/null | wc -l)
        if [ "$SNAP_COUNT" -le 1 ]; then
            echo "  Only $SNAP_COUNT snapshot(s) — keeping all (never delete the last)"
        else
            # Find the newest snapshot to protect it
            NEWEST=$(ls -t "$SNAPSHOT_DIR"/snapshot-*.json.gz 2>/dev/null | head -1)
            NEWEST_HEIGHT=$(basename "$NEWEST" | sed 's/snapshot-//;s/.json.gz//')
            DELETED=0
            for f in "$SNAPSHOT_DIR"/snapshot-*.json.gz; do
                [ -f "$f" ] || continue
                # Never delete the newest
                [ "$f" = "$NEWEST" ] && continue
                FILE_AGE=$(( NOW - $(stat -c %Y "$f") ))
                if [ "$FILE_AGE" -gt "$RETENTION_SECS" ]; then
                    HEIGHT=$(basename "$f" | sed 's/snapshot-//;s/.json.gz//')
                    echo "  Deleting: snapshot-${HEIGHT} (age: $((FILE_AGE / 3600))h)"
                    rm -f "$SNAPSHOT_DIR/snapshot-${HEIGHT}.json.gz"
                    rm -f "$SNAPSHOT_DIR/manifest-${HEIGHT}.json"
                    DELETED=$((DELETED + 1))
                fi
            done
            echo "  Purged $DELETED old snapshot(s), kept newest (height $NEWEST_HEIGHT)"
        fi
    else
        echo "  No snapshot directory"
    fi
fi

# ---- GitHub purge ----
if $PURGE_GITHUB; then
    echo ""
    echo "--- GitHub purge ($REPO) ---"
    # List all releases sorted by date (newest first)
    RELEASES=$(gh release list --repo "$REPO" --limit 100 --json tagName,createdAt \
        --jq '.[] | select(.tagName | startswith("snapshot-")) | "\(.tagName)\t\(.createdAt)"' 2>/dev/null || true)

    TOTAL=$(echo "$RELEASES" | grep -c "^snapshot-" || echo 0)
    if [ "$TOTAL" -le 1 ]; then
        echo "  Only $TOTAL release(s) — keeping all (never delete the last)"
    else
        DELETED=0
        FIRST=true
        while IFS=$'\t' read -r TAG CREATED; do
            [ -z "$TAG" ] && continue
            # Always keep the first (newest) release
            if $FIRST; then
                FIRST=false
                echo "  Keeping newest: $TAG"
                continue
            fi
            RELEASE_TS=$(date -d "$CREATED" +%s 2>/dev/null || echo 0)
            AGE=$(( NOW - RELEASE_TS ))
            if [ "$AGE" -gt "$RETENTION_SECS" ]; then
                echo "  Deleting: $TAG (age: $((AGE / 3600))h)"
                gh release delete "$TAG" --repo "$REPO" --yes --cleanup-tag 2>/dev/null || true
                DELETED=$((DELETED + 1))
            fi
        done <<< "$RELEASES"
        echo "  Purged $DELETED old release(s)"
    fi
fi

echo ""
echo "=== Purge complete ==="
