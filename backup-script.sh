#!/bin/sh
set -euo pipefail

echo "=== Vaultwarden backup daemon starting ==="

# Configure rclone for Cloudflare R2
mkdir -p ~/.config/rclone
cat > ~/.config/rclone/rclone.conf << EOF
[r2]
type = s3
provider = Cloudflare
access_key_id = ${R2_ACCESS_KEY_ID}
secret_access_key = ${R2_SECRET_ACCESS_KEY}
endpoint = ${R2_BUCKET_ENDPOINT}
acl = private
EOF
chmod 600 ~/.config/rclone/rclone.conf

# Fixed remote filename — always overwrites, guarantees exactly 1 backup in R2
REMOTE_FILE="r2:${R2_BUCKET_NAME}/vaultwarden_latest.tar.gz.gpg"

run_backup() {
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    WORKDIR="/tmp/vw_backup_${TIMESTAMP}"
    TAR_FILE="/tmp/vaultwarden_${TIMESTAMP}.tar.gz"
    ENC_FILE="/tmp/vaultwarden_${TIMESTAMP}.tar.gz.gpg"

    mkdir -p "${WORKDIR}"

    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Starting backup..."

    # Hot backup of SQLite — safe under concurrent writes
    sqlite3 /data/db.sqlite3 ".backup '${WORKDIR}/db.sqlite3'"

    # Copy supplementary data if present
    [ -d /data/attachments ] && cp -r /data/attachments "${WORKDIR}/"
    [ -d /data/sends ]       && cp -r /data/sends       "${WORKDIR}/"
    [ -f /data/config.json ] && cp    /data/config.json "${WORKDIR}/"
    [ -f /data/rsa_key.pem ] && cp    /data/rsa_key.pem "${WORKDIR}/"

    tar -czf "${TAR_FILE}" -C "${WORKDIR}" .

    # AES-256 symmetric encryption
    # --s2k-count 65011712 = max KDF iterations (brute-force resistant)
    # --force-mdc ensures message integrity (prevents ciphertext tampering)
    printf '%s' "${BACKUP_PASSPHRASE}" | gpg --batch --yes \
        --passphrase-fd 0 \
        --symmetric \
        --cipher-algo AES256 \
        --digest-algo SHA512 \
        --s2k-mode 3 \
        --s2k-digest-algo SHA512 \
        --s2k-count 65011712 \
        --force-mdc \
        --output "${ENC_FILE}" \
        "${TAR_FILE}"

    # Upload — overwrites the single remote file atomically
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Uploading to R2..."
    rclone copyto "${ENC_FILE}" "${REMOTE_FILE}" \
        --s3-no-check-bucket \
        --retries 3 \
        --retries-sleep 10s

    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Backup complete. Remote: ${REMOTE_FILE}"

    # Cleanup temp files
    rm -rf "${WORKDIR}" "${TAR_FILE}" "${ENC_FILE}"
}

# Run immediately on startup, then every BACKUP_INTERVAL seconds
while true; do
    if run_backup; then
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Success."
    else
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR: backup failed — will retry next cycle."
    fi

    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Sleeping ${BACKUP_INTERVAL}s until next backup..."
    sleep "${BACKUP_INTERVAL}"
done
