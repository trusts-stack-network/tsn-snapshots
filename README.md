# TSN Blockchain Snapshots

Signed state snapshots for fast chain restoration on the [Trust Stack Network](https://tsnchain.com).

## What is this?

This repository contains verified state snapshots of the TSN blockchain. Each snapshot allows a new node to synchronize in seconds instead of replaying the entire chain history.

## Security Model

Every snapshot is cryptographically verified through a multi-seed confirmation process:

1. **Producer signature** — The seed that exports the snapshot signs the manifest with its Ed25519 key
2. **Cross-seed confirmations** — At least 2 other independent seed nodes verify the block hash and state root at the snapshot height, then sign their own confirmation
3. **SHA256 integrity** — The compressed snapshot file hash is embedded in the manifest
4. **State root verification** — After import, the node recomputes the state root and compares it with the manifest

## Snapshot Format

Each snapshot consists of two files:

- `snapshot-{height}.json.gz` — Compressed state snapshot (gzip JSON)
- `manifest-{height}.json` — Signed manifest with confirmations

## Verification

To verify a snapshot manually:

```bash
# Download and verify
./scripts/verify-snapshot.sh manifest-12000.json snapshot-12000.json.gz
```

This checks:
- Producer Ed25519 signature against the known public key
- SHA256 of the snapshot file matches the manifest
- At least 2 seed confirmations are cryptographically valid

## Public Keys

Seed signing public keys are in `public-keys/`. These are the Ed25519 verification keys for each seed node.

## Retention Policy

Snapshots are retained for **24 hours** on a rolling basis. Older snapshots are automatically purged from both this repository and the seed nodes.

## Restoring from a Snapshot

```bash
# Stop your node
systemctl stop tsn-node

# Download latest snapshot + manifest
curl -LO https://github.com/trusts-stack-network/tsn-snapshots/releases/latest/download/snapshot.json.gz
curl -LO https://github.com/trusts-stack-network/tsn-snapshots/releases/latest/download/manifest.json

# Verify before importing
./scripts/verify-snapshot.sh manifest.json snapshot.json.gz

# Import (your node handles this automatically during fast-sync)
systemctl start tsn-node
```

## License

MIT
