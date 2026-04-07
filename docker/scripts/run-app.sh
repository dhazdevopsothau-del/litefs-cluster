#!/bin/bash
# run-app.sh — Chạy bởi LiteFS sau khi FUSE mount xong
# Chạy trên cả primary lẫn replica:
#   - Primary: ghi heartbeat vào SQLite
#   - Replica: đọc và verify replication
# Không dùng set -e vì SQLite error trên replica là bình thường

LOG_P="[APP]"
DB="/mnt/litefs/cluster.db"

log()  { echo "$LOG_P [$(date '+%H:%M:%S')] $*"; }
info() { echo "$LOG_P [INFO]  $*"; }

MY_IP=$(tailscale ip -4 2>/dev/null || echo "unknown")
MY_NODE=$(hostname | cut -c1-12)

log "═══════════════════════════════════════════"
log "  App started"
log "  Node : $MY_NODE"
log "  IP   : $MY_IP"
log "═══════════════════════════════════════════"

# ── Check xem mình có phải LiteFS primary không ──────────────────────────────
# Cách đáng tin cậy nhất: check Consul KV do LiteFS set
is_primary() {
    local kv
    kv=$(consul kv get litefs/primary 2>/dev/null || true)
    # Value dạng: {"hostname":"...", "advertise-url":"http://100.x.x.x:20202"}
    echo "$kv" | grep -q "$MY_IP"
}

# ── Chờ DB accessible ─────────────────────────────────────────────────────────
# Pitfall: Sau khi LiteFS mount, replica phải đợi sync từ primary
# Có thể mất vài giây trước khi file xuất hiện trong /mnt/litefs
wait_db() {
    log "Waiting for database to be accessible..."
    local i=0
    while [ $i -lt 30 ]; do
        if sqlite3 "$DB" "SELECT 1;" &>/dev/null 2>&1; then
            log "✓ DB accessible"
            return 0
        fi
        sleep 2
        i=$((i + 1))
    done
    log "⚠ DB not accessible after 60s (may be first start or replica sync pending)"
}

# ── Init schema (primary only) ────────────────────────────────────────────────
init_db() {
    log "Initializing DB schema (PRIMARY)..."
    sqlite3 "$DB" <<'SQL'
CREATE TABLE IF NOT EXISTS cluster_nodes (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    node_ip   TEXT    NOT NULL UNIQUE,
    node_name TEXT    NOT NULL,
    role      TEXT    NOT NULL DEFAULT 'member',
    joined_at TEXT    DEFAULT (datetime('now'))
);
CREATE TABLE IF NOT EXISTS heartbeats (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    node_ip   TEXT    NOT NULL,
    node_name TEXT    NOT NULL,
    message   TEXT    NOT NULL,
    ts        TEXT    DEFAULT (datetime('now'))
);
SQL
    log "✓ Schema ready"
}

# ── Register node ─────────────────────────────────────────────────────────────
register_node() {
    local role="$1"
    sqlite3 "$DB" \
        "INSERT OR REPLACE INTO cluster_nodes(node_ip, node_name, role, joined_at)
         VALUES('$MY_IP', '$MY_NODE', '$role', datetime('now'));" \
        2>/dev/null && log "✓ Registered as $role" || log "⚠ Register skipped (replica?)"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    # Đợi LiteFS elect primary (cần Consul sẵn sàng)
    sleep 8
    wait_db

    # Xác định role
    if is_primary; then
        log "★  I am LiteFS PRIMARY"
        init_db
        register_node "primary"
    else
        log "→  I am LiteFS REPLICA"
        # Replicas vẫn register (nếu fail sẽ retry khi thành primary)
        register_node "replica"
    fi

    # Heartbeat loop
    local tick=0
    while true; do
        tick=$((tick + 1))
        sleep 30

        if is_primary; then
            # Ghi heartbeat — nếu fail thì log warning, không exit
            if sqlite3 "$DB" \
                "INSERT INTO heartbeats(node_ip, node_name, message)
                 VALUES('$MY_IP', '$MY_NODE', 'tick-$tick @ $(date -u +%T)');" \
                2>/dev/null; then
                log "♥ [PRIMARY] wrote tick #$tick"
            else
                log "⚠ [PRIMARY] write failed tick #$tick (transitioning?)"
            fi
        else
            # Đọc count từ replica — prove replication working
            local cnt
            cnt=$(sqlite3 "$DB" "SELECT COUNT(*) FROM heartbeats;" 2>/dev/null || echo "?")
            local primary_kv
            primary_kv=$(consul kv get litefs/primary 2>/dev/null \
                | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('advertise-url','?'))" \
                2>/dev/null || echo "?")
            log "♥ [REPLICA] tick #$tick | DB heartbeats: $cnt | Primary: $primary_kv"
        fi
    done
}

main "$@"
