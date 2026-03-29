#!/bin/bash
#
# Monitor the POC remotely via 'az vm run-command'.
# Use this when you cannot SSH directly into the VMs.
#
# Usage:
#   ./monitor-remote.sh                  # check both VMs
#   ./monitor-remote.sh --primary        # check primary only
#   ./monitor-remote.sh --secondary      # check secondary only
#   ./monitor-remote.sh --takeover       # show takeover events only
#
set -euo pipefail

RG="jbhushan-zone-down-poc-rg"
PRIMARY_VM="jbhushan-zrs-primary"
SECONDARY_VM="jbhushan-zrs-secondary"
CHECK_PRIMARY=true
CHECK_SECONDARY=true
SCRIPT='echo "--- Service ---" && systemctl is-active zonedown-ROLE 2>/dev/null && echo "ACTIVE" || echo "INACTIVE"; echo "--- Disks ---" && lsblk -d -o NAME,TRAN 2>/dev/null | grep -c iscsi || echo 0; echo "--- Log (last 20) ---" && tail -20 /var/log/poc/ROLE.log 2>/dev/null || echo "No log"'
TAKEOVER=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --primary)   CHECK_SECONDARY=false; shift ;;
    --secondary) CHECK_PRIMARY=false; shift ;;
    --takeover)  TAKEOVER=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

run_on_vm() {
  local vm="$1" role="$2"
  local cmd
  if $TAKEOVER; then
    cmd="grep -E 'TAKEOVER|PREEMPTED|preempt|acquired|lost|standby|acting|persistent write' /var/log/poc/${role}.log 2>/dev/null || echo 'No events'"
  else
    cmd=$(echo "$SCRIPT" | sed "s/ROLE/${role}/g")
  fi
  echo "========================================"
  echo " $vm ($role)"
  echo "========================================"
  az vm run-command invoke \
    --resource-group "$RG" \
    --name "$vm" \
    --command-id RunShellScript \
    --scripts "$cmd" \
    -o json 2>&1 | python3 -c "import sys,json; [print(v['message']) for v in json.load(sys.stdin).get('value',[])]" 2>/dev/null || echo "  (VM unreachable or stopped)"
  echo ""
}

if $CHECK_PRIMARY; then
  run_on_vm "$PRIMARY_VM" "primary"
fi
if $CHECK_SECONDARY; then
  run_on_vm "$SECONDARY_VM" "secondary"
fi
