#!/bin/bash
#
# Sets up a VM for the zone-down failover POC.
# Run this on each VM (primary and secondary) after the Azure infrastructure
# is created and the VMs are provisioned.
#
# What it does:
#   1. Installs required packages (open-iscsi, sg3-utils)
#   2. Discovers and connects all Elastic SAN iSCSI volumes
#   3. Builds the Go binaries from source
#   4. Installs systemd service files
#   5. Enables all services for auto-start on boot
#
# Usage:
#   ./setup-vm.sh --name <prefix> --role primary --remote-ip <SECONDARY_IP> --portal <PORTAL>
#   ./setup-vm.sh --name <prefix> --role secondary --portal <PORTAL>
#
set -euo pipefail

NAME_PREFIX="jbhushan"
ROLE=""
REMOTE_IP=""
PORTAL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)      NAME_PREFIX="$2"; shift 2 ;;
    --role)      ROLE="$2"; shift 2 ;;
    --remote-ip) REMOTE_IP="$2"; shift 2 ;;
    --portal)    PORTAL="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 --name PREFIX --role <primary|secondary> --portal <host:port> [--remote-ip <IP>]"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

RG="${NAME_PREFIX}-zone-down-poc-rg"
ESAN_NAME="${NAME_PREFIX}-zrs-esan"
VG_NAME="${NAME_PREFIX}-zrs-vg"

if [[ -z "$ROLE" || -z "$PORTAL" ]]; then
  echo "Usage: $0 --name PREFIX --role <primary|secondary> --portal <host:port> [--remote-ip <IP>]"
  exit 1
fi
if [[ "$ROLE" == "primary" && -z "$REMOTE_IP" ]]; then
  echo "Primary role requires --remote-ip <secondary_ip>"
  exit 1
fi

echo "=== Role: $ROLE ==="

# --- Install packages ---
echo "=== Installing packages ==="
if command -v tdnf &>/dev/null; then
  tdnf install -y iscsi-initiator-utils sg3_utils golang
elif command -v apt-get &>/dev/null; then
  apt-get update -qq
  apt-get install -y open-iscsi sg3-utils golang-go
elif command -v yum &>/dev/null; then
  yum install -y iscsi-initiator-utils sg3_utils golang
else
  echo "ERROR: No supported package manager found"
  exit 1
fi

# --- Start iSCSI daemon ---
systemctl enable --now iscsid

# --- Discover and connect iSCSI targets ---
echo "=== Discovering iSCSI targets on $PORTAL ==="
IQNS=$(az elastic-san volume list \
  --elastic-san-name "$ESAN_NAME" \
  --volume-group-name "$VG_NAME" \
  --resource-group "$RG" \
  -o json 2>/dev/null | python3 -c "
import sys, json
vols = sorted(json.load(sys.stdin), key=lambda v: v['name'])
for v in vols:
    print(v.get('storageTarget',{}).get('targetIqn',''))
" 2>/dev/null || true)

if [[ -z "$IQNS" ]]; then
  echo "ERROR: Could not retrieve volume IQNs. Ensure az CLI is logged in."
  exit 1
fi

echo "=== Creating iSCSI node records and logging in ==="
while IFS= read -r IQN; do
  [[ -z "$IQN" ]] && continue
  VOL="${IQN##*:}"
  echo "  $VOL"
  iscsiadm -m node --op=new -T "$IQN" -p "$PORTAL" 2>/dev/null || true
  iscsiadm -m node -T "$IQN" -p "$PORTAL" --login 2>/dev/null || true
done <<< "$IQNS"

sleep 5
DISK_COUNT=$(lsblk -d -o NAME,TRAN | grep -c iscsi || true)
echo "=== Connected $DISK_COUNT iSCSI disks ==="
lsblk -d -o NAME,SIZE,TRAN,MODEL | grep -E "sd|NAME"

# --- Build device list ---
DEVICES=$(lsblk -d -n -o NAME,TRAN | grep iscsi | awk '{print "/dev/"$1}' | sort | tr '\n' ',' | sed 's/,$//')
echo "=== Device list: $DEVICES ==="

# --- Build Go binaries ---
echo "=== Building Go binaries ==="
export HOME=/root
export GOCACHE=/root/.cache/go-build
export GOEXPERIMENT=ms_nocgo_opensslcrypto
export CGO_ENABLED=0

mkdir -p /root/poc
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."
go build -o /root/poc/primary primary_main.go
go build -o /root/poc/secondary secondary_main.go
echo "  Binaries built in /root/poc/"

# --- Install systemd services ---
echo "=== Installing systemd services ==="

cp systemd/iscsi-esan.service /etc/systemd/system/
cp systemd/iptables-poc.service /etc/systemd/system/

if [[ "$ROLE" == "primary" ]]; then
  sed "s|<SECONDARY_IP>|$REMOTE_IP|g" systemd/zonedown-primary.service > /etc/systemd/system/zonedown-primary.service
  # Update device list in service file
  sed -i "s|--devices [^ ]*|--devices $DEVICES|" /etc/systemd/system/zonedown-primary.service
  SVC_NAME="zonedown-primary"
else
  cp systemd/zonedown-secondary.service /etc/systemd/system/
  sed -i "s|--devices [^ ]*|--devices $DEVICES|" /etc/systemd/system/zonedown-secondary.service
  SVC_NAME="zonedown-secondary"
fi

mkdir -p /var/log/poc

systemctl daemon-reload
systemctl enable iscsi-esan iptables-poc "$SVC_NAME"

echo ""
echo "=== Setup complete (role: $ROLE) ==="
echo ""
echo "Services enabled (will auto-start on boot):"
echo "  - iscsi-esan.service"
echo "  - iptables-poc.service"
echo "  - $SVC_NAME.service"
echo ""
echo "To start now:"
echo "  systemctl start iscsi-esan iptables-poc $SVC_NAME"
echo ""
echo "Logs: /var/log/poc/${ROLE}.log"
