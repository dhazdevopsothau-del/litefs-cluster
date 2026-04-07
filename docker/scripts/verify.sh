#!/bin/bash
# verify.sh — Chứng minh cluster hoạt động đúng
# Chạy từ ngoài: docker exec litefs-node-a /usr/local/bin/verify.sh
set -euo pipefail

DB="/mnt/litefs/cluster.db"
SEP="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

s() { echo -e "\n$SEP\n  $1\n$SEP"; }

MY_IP=$(tailscale ip -4 2>/dev/null || echo "N/A")
MY_NODE=$(hostname | cut -c1-12)

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║       LITEFS CLUSTER VERIFICATION           ║"
echo "║  Node: $MY_NODE  IP: $MY_IP"
echo "╚══════════════════════════════════════════════╝"

# ── 1. Tailscale ─────────────────────────────────────────────────────────────
s "1. TAILSCALE STATUS"
tailscale status
echo ""
echo "My Tailscale IP: $MY_IP"

# ── 2. Consul members ─────────────────────────────────────────────────────────
s "2. CONSUL MEMBERS"
consul members -detailed 2>/dev/null || echo "Consul not reachable"

# ── 3. Consul leader ──────────────────────────────────────────────────────────
s "3. CONSUL RAFT LEADER"
echo -n "Current leader: "
curl -s http://localhost:8500/v1/status/leader 2>/dev/null || echo "N/A"
echo ""
echo "All Raft peers:"
curl -s http://localhost:8500/v1/status/peers 2>/dev/null | jq -r '.[]' || echo "N/A"

# ── 4. LiteFS primary ─────────────────────────────────────────────────────────
s "4. LITEFS PRIMARY (via Consul KV)"
RAW_KV=$(consul kv get litefs/primary 2>/dev/null || echo "not set")
echo "Raw KV value : $RAW_KV"

# Parse JSON value nếu có
if echo "$RAW_KV" | python3 -c "import sys,json; d=json.load(sys.stdin); \
   print(f\"Advertise URL : {d.get('advertise-url','?')}\n\
Hostname      : {d.get('hostname','?')}\")" 2>/dev/null; then
    true
fi

# Check nếu mình là primary
if echo "$RAW_KV" | grep -q "$MY_IP" 2>/dev/null; then
    echo "★  THIS NODE IS LITEFS PRIMARY"
else
    echo "→  This node is a REPLICA"
fi

# ── 5. FUSE mount ─────────────────────────────────────────────────────────────
s "5. LITEFS FUSE MOUNT"
if mountpoint -q /mnt/litefs 2>/dev/null; then
    echo "✓ /mnt/litefs is mounted"
    echo "  Files:"
    ls -lah /mnt/litefs/ 2>/dev/null | sed 's/^/    /' || echo "    (empty)"
else
    echo "✗ /mnt/litefs is NOT mounted"
fi

# ── 6. Database content ───────────────────────────────────────────────────────
s "6. DATABASE CONTENT"

if ! sqlite3 "$DB" "SELECT 1;" &>/dev/null 2>&1; then
    echo "⚠ Database not accessible (replica may still be syncing)"
else
    echo "--- cluster_nodes ---"
    sqlite3 -column -header "$DB" \
        "SELECT id, node_ip, node_name, role, joined_at FROM cluster_nodes ORDER BY id;" \
        2>/dev/null || echo "(table not yet created)"

    echo ""
    echo "--- heartbeats (latest 10) ---"
    sqlite3 -column -header "$DB" \
        "SELECT id, node_ip, node_name, message, ts FROM heartbeats ORDER BY id DESC LIMIT 10;" \
        2>/dev/null || echo "(table not yet created)"

    echo ""
    echo "--- stats ---"
    TOTAL=$(sqlite3 "$DB" "SELECT COUNT(*) FROM heartbeats;" 2>/dev/null || echo "?")
    NODES=$(sqlite3 "$DB" "SELECT COUNT(DISTINCT node_ip) FROM heartbeats;" 2>/dev/null || echo "?")
    echo "  Total heartbeats : $TOTAL"
    echo "  Unique writers   : $NODES"

    # Chứng minh replication: nếu có heartbeat từ node khác → replication đang hoạt động
    echo ""
    echo "--- writers breakdown (proves replication) ---"
    sqlite3 -column -header "$DB" \
        "SELECT node_name, node_ip, COUNT(*) as count, MAX(ts) as last_write
         FROM heartbeats
         GROUP BY node_ip
         ORDER BY count DESC;" \
        2>/dev/null || echo "(no data yet)"
fi

# ── 7. Logs tail ──────────────────────────────────────────────────────────────
s "7. RECENT LOGS (last 5 lines each)"
echo "--- consul.log ---"
tail -5 /var/log/consul.log 2>/dev/null | sed 's/^/  /' || echo "  (empty)"
echo "--- tailscaled.log ---"
tail -5 /var/log/tailscaled.log 2>/dev/null | sed 's/^/  /' || echo "  (empty)"

echo ""
echo "$SEP"
echo "  VERIFICATION COMPLETE — $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "$SEP"
echo ""
