#!/bin/bash
#
# Monitor the zone-down failover POC.
# Run locally or via 'az vm run-command' to check status on either VM.
#
# Usage:
#   ./monitor.sh                    # auto-detect role from running services
#   ./monitor.sh --role primary
#   ./monitor.sh --role secondary
#   ./monitor.sh --takeover-events  # show only takeover/preemption events
#
set -euo pipefail

ROLE=""
TAKEOVER_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --role)             ROLE="$2"; shift 2 ;;
    --takeover-events)  TAKEOVER_ONLY=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# Auto-detect role
if [[ -z "$ROLE" ]]; then
  if systemctl is-active --quiet zonedown-primary 2>/dev/null; then
    ROLE="primary"
  elif systemctl is-active --quiet zonedown-secondary 2>/dev/null; then
    ROLE="secondary"
  else
    echo "Could not detect role. Use --role primary|secondary"
    exit 1
  fi
fi

LOG="/var/log/poc/${ROLE}.log"

echo "========================================"
echo " Zone-Down POC Monitor — $ROLE"
echo "========================================"
echo ""

# Service status
echo "--- Service Status ---"
systemctl is-active "zonedown-${ROLE}" 2>/dev/null && echo "  zonedown-${ROLE}: ACTIVE" || echo "  zonedown-${ROLE}: INACTIVE"
systemctl is-active iscsi-esan 2>/dev/null && echo "  iscsi-esan: ACTIVE" || echo "  iscsi-esan: INACTIVE"
systemctl is-active iptables-poc 2>/dev/null && echo "  iptables-poc: ACTIVE" || echo "  iptables-poc: INACTIVE"
echo ""

# iSCSI volumes
echo "--- iSCSI Volumes ---"
DISK_COUNT=$(lsblk -d -o NAME,TRAN 2>/dev/null | grep -c iscsi || echo "0")
echo "  Connected: $DISK_COUNT disks"
lsblk -d -o NAME,SIZE,TRAN 2>/dev/null | grep iscsi || true
echo ""

# Log files
echo "--- Log Files ---"
ls -lh /var/log/poc/ 2>/dev/null || echo "  No log directory"
echo ""

if [[ ! -f "$LOG" ]]; then
  echo "Log file $LOG not found."
  exit 0
fi

if $TAKEOVER_ONLY; then
  echo "--- Takeover / Preemption Events ---"
  grep -E "TAKEOVER|PREEMPTED|preempt|acquired|lost|standby|acting|persistent write" "$LOG" || echo "  No events found"
else
  echo "--- Latest Log (last 30 lines) ---"
  tail -30 "$LOG"
fi
