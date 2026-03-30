#!/bin/bash
#
# End-to-end setup for the Azure Elastic SAN zone-down failover POC.
# Run this from any machine with Azure CLI logged in. It will:
#
#   1. Create resource group, VNet, subnet, NSG
#   2. Create Elastic SAN with volume group and N volumes
#   3. Create two VMs in different availability zones
#   4. Remotely install packages on both VMs (via az vm run-command)
#   5. Connect all iSCSI volumes on both VMs
#   6. Upload Go source, build binaries on both VMs
#   7. Install systemd services and start them
#
# Usage:
#   ./scripts/setup.sh --name myprefix
#   ./scripts/setup.sh --name myprefix --location westus2 --vm-size Standard_D4s_v5
#   ./scripts/setup.sh --help
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Defaults ---
NAME_PREFIX="jbhushan"
LOCATION="eastus2"
VOL_COUNT=10
VOL_SIZE_GIB=1
ESAN_BASE_SIZE_TIB=1
VNET_PREFIX="10.163.0.0/24"
VM_SIZE="Standard_E8ds_v6"
VM_IMAGE="MicrosoftCBLMariner:azure-linux-3:azure-linux-3-gen2:latest"
ADMIN_USER="client"
SSH_PUB_KEY="${SSH_PUB_KEY:-$HOME/.ssh/id_rsa.pub}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)           NAME_PREFIX="$2"; shift 2 ;;
    --location)       LOCATION="$2"; shift 2 ;;
    --vol-count)      VOL_COUNT="$2"; shift 2 ;;
    --vol-size-gib)   VOL_SIZE_GIB="$2"; shift 2 ;;
    --esan-size-tib)  ESAN_BASE_SIZE_TIB="$2"; shift 2 ;;
    --vnet-prefix)    VNET_PREFIX="$2"; shift 2 ;;
    --vm-size)        VM_SIZE="$2"; shift 2 ;;
    --vm-image)       VM_IMAGE="$2"; shift 2 ;;
    --admin-user)     ADMIN_USER="$2"; shift 2 ;;
    --ssh-key)        SSH_PUB_KEY="$2"; shift 2 ;;
    -h|--help)
      cat <<'USAGE'
Usage: setup.sh [--name PREFIX] [OPTIONS]

Creates the complete POC environment: Azure infrastructure + VM configuration.

Options:
  --name PREFIX       Name prefix for all resources (default: jbhushan)
  --location REGION   Azure region (default: eastus2)
  --vol-count N       Number of Elastic SAN volumes (default: 10)
  --vol-size-gib N    Size of each volume in GiB (default: 1)
  --esan-size-tib N   Elastic SAN base size in TiB (default: 1)
  --vnet-prefix CIDR  VNet address space (default: 10.163.0.0/24)
  --vm-size SIZE      VM SKU (default: Standard_E8ds_v6)
  --vm-image IMAGE    VM image URN (default: Azure Linux 3)
  --admin-user USER   VM admin username (default: client)
  --ssh-key PATH      Path to SSH public key (default: ~/.ssh/id_rsa.pub)
USAGE
      exit 0
      ;;
    *) echo "Unknown option: $1. Use --help for usage."; exit 1 ;;
  esac
done

SSH_ARGS=(--ssh-key-values "$SSH_PUB_KEY")
if [[ ! -f "$SSH_PUB_KEY" ]]; then
  SSH_ARGS=(--generate-ssh-keys)
fi

if [[ ! "$NAME_PREFIX" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
  echo "ERROR: --name must contain only lowercase letters, digits, and hyphens (no underscores, no leading/trailing hyphens)."
  echo "  Got: '$NAME_PREFIX'"
  echo "  Example: --name my-project"
  exit 1
fi

# --- Derived names ---
RG="${NAME_PREFIX}-zone-down-poc-rg"
ESAN_NAME="${NAME_PREFIX}-zrs-esan"
VG_NAME="${NAME_PREFIX}-zrs-vg"
VOL_PREFIX="${NAME_PREFIX}-zrs-vol"
VNET_NAME="${NAME_PREFIX}-zrs-vnet"
SUBNET_NAME="${NAME_PREFIX}-zrs-subnet"
NSG_NAME="${NAME_PREFIX}-zrs-nsg"
PRIMARY_VM="${NAME_PREFIX}-zrs-primary"
SECONDARY_VM="${NAME_PREFIX}-zrs-secondary"

# Helper: run a script on a VM via az vm run-command, print stdout/stderr
run_on_vm() {
  local vm="$1"; shift
  local output
  if ! output=$(az vm run-command invoke \
    --resource-group "$RG" \
    --name "$vm" \
    --command-id RunShellScript \
    --scripts "$@" \
    -o json 2>&1); then
    echo "  ERROR running command on $vm:"
    echo "$output" | tail -5
    return 1
  fi
  echo "$output" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for v in data.get('value', []):
        print(v.get('message',''))
except Exception as e:
    print(f'  (failed to parse response: {e})')
    print(sys.stdin.read()[:500])
"
}

echo "============================================="
echo " Zone-Down Failover POC — Full Setup"
echo " Prefix: ${NAME_PREFIX}"
echo "============================================="
echo ""

# =============================================
# PHASE 1: Azure Infrastructure (idempotent)
# =============================================

echo "=== [1/10] Resource group ==="
if az group show --name "$RG" -o none 2>/dev/null; then
  echo "  $RG already exists — reusing"
else
  az group create --name "$RG" --location "$LOCATION" -o none
  echo "  $RG created ($LOCATION)"
fi

echo ""
echo "=== [2/10] VNet, subnet, and NSG ==="
if az network vnet show --resource-group "$RG" --name "$VNET_NAME" -o none 2>/dev/null; then
  echo "  $VNET_NAME already exists — reusing"
else
  az network vnet create \
    --resource-group "$RG" \
    --name "$VNET_NAME" \
    --address-prefix "$VNET_PREFIX" \
    --subnet-name "$SUBNET_NAME" \
    --subnet-prefix "$VNET_PREFIX" \
    -o none
  echo "  $VNET_NAME / $SUBNET_NAME created"
fi

if az network nsg show --resource-group "$RG" --name "$NSG_NAME" -o none 2>/dev/null; then
  echo "  $NSG_NAME already exists — reusing"
else
  az network nsg create \
    --resource-group "$RG" \
    --name "$NSG_NAME" \
    -o none

  az network nsg rule create \
    --resource-group "$RG" \
    --nsg-name "$NSG_NAME" \
    --name AllowVNetInternal \
    --priority 110 \
    --direction Inbound \
    --access Allow \
    --protocol '*' \
    --source-address-prefixes VirtualNetwork \
    --destination-address-prefixes VirtualNetwork \
    --destination-port-ranges '*' \
    -o none

  az network vnet subnet update \
    --resource-group "$RG" \
    --vnet-name "$VNET_NAME" \
    --name "$SUBNET_NAME" \
    --network-security-group "$NSG_NAME" \
    -o none
  echo "  $NSG_NAME created and attached"
fi

echo ""
echo "=== [3/10] Elastic SAN ==="
if az elastic-san show --elastic-san-name "$ESAN_NAME" --resource-group "$RG" -o none 2>/dev/null; then
  echo "  $ESAN_NAME already exists — reusing"
else
  az elastic-san create \
    --elastic-san-name "$ESAN_NAME" \
    --resource-group "$RG" \
    --location "$LOCATION" \
    --base-size-tib "$ESAN_BASE_SIZE_TIB" \
    --extended-capacity-size-tib 0 \
    --sku '{name:Premium_ZRS,tier:Premium}' \
    -o none
  echo "  $ESAN_NAME created (Premium_ZRS, ${ESAN_BASE_SIZE_TIB} TiB)"
fi

if az elastic-san volume-group show --elastic-san-name "$ESAN_NAME" --volume-group-name "$VG_NAME" --resource-group "$RG" -o none 2>/dev/null; then
  echo "  $VG_NAME already exists — reusing"
else
  az elastic-san volume-group create \
    --elastic-san-name "$ESAN_NAME" \
    --volume-group-name "$VG_NAME" \
    --resource-group "$RG" \
    -o none
  echo "  $VG_NAME created"
fi

SUBNET_ID=$(az network vnet subnet show \
  --resource-group "$RG" \
  --vnet-name "$VNET_NAME" \
  --name "$SUBNET_NAME" \
  --query id -o tsv)

echo "  Ensuring subnet network ACL on volume group..."
az elastic-san volume-group update \
  --elastic-san-name "$ESAN_NAME" \
  --volume-group-name "$VG_NAME" \
  --resource-group "$RG" \
  --network-acls virtual-network-rules="[{id:$SUBNET_ID,action:Allow}]" \
  -o none
echo "  Subnet $SUBNET_NAME allowed on $VG_NAME"

echo ""
echo "=== [4/10] Volumes ==="
EXISTING_VOLS=$(az elastic-san volume list \
  --elastic-san-name "$ESAN_NAME" \
  --volume-group-name "$VG_NAME" \
  --resource-group "$RG" \
  --query "[].name" -o tsv 2>/dev/null || true)

for i in $(seq -w 1 "$VOL_COUNT"); do
  VOL_NAME="${VOL_PREFIX}-$i"
  if echo "$EXISTING_VOLS" | grep -qx "$VOL_NAME"; then
    echo "  $VOL_NAME exists — reusing"
  else
    az elastic-san volume create \
      --elastic-san-name "$ESAN_NAME" \
      --volume-group-name "$VG_NAME" \
      --name "$VOL_NAME" \
      --size-gib "$VOL_SIZE_GIB" \
      --resource-group "$RG" \
      -o none
    echo "  $VOL_NAME created (${VOL_SIZE_GIB} GiB)"
  fi
done

echo ""
echo "=== [5/10] VMs ==="
if az vm show --resource-group "$RG" --name "$PRIMARY_VM" -o none 2>/dev/null; then
  echo "  $PRIMARY_VM already exists"
  POWER=$(az vm get-instance-view --resource-group "$RG" --name "$PRIMARY_VM" \
    --query "instanceView.statuses[1].displayStatus" -o tsv 2>/dev/null || echo "unknown")
  if [[ "$POWER" == "VM deallocated" || "$POWER" == "VM stopped" ]]; then
    echo "  $PRIMARY_VM is $POWER — starting..."
    az vm start --resource-group "$RG" --name "$PRIMARY_VM" -o none
  fi
else
  echo "  Creating $PRIMARY_VM (zone 1)..."
  az vm create \
    --resource-group "$RG" \
    --name "$PRIMARY_VM" \
    --image "$VM_IMAGE" \
    --size "$VM_SIZE" \
    --zone 1 \
    --vnet-name "$VNET_NAME" \
    --subnet "$SUBNET_NAME" \
    --nsg "$NSG_NAME" \
    --admin-username "$ADMIN_USER" \
    "${SSH_ARGS[@]}" \
    --public-ip-sku Standard \
    -o none
fi

if az vm show --resource-group "$RG" --name "$SECONDARY_VM" -o none 2>/dev/null; then
  echo "  $SECONDARY_VM already exists"
  POWER=$(az vm get-instance-view --resource-group "$RG" --name "$SECONDARY_VM" \
    --query "instanceView.statuses[1].displayStatus" -o tsv 2>/dev/null || echo "unknown")
  if [[ "$POWER" == "VM deallocated" || "$POWER" == "VM stopped" ]]; then
    echo "  $SECONDARY_VM is $POWER — starting..."
    az vm start --resource-group "$RG" --name "$SECONDARY_VM" -o none
  fi
else
  echo "  Creating $SECONDARY_VM (zone 2)..."
  az vm create \
    --resource-group "$RG" \
    --name "$SECONDARY_VM" \
    --image "$VM_IMAGE" \
    --size "$VM_SIZE" \
    --zone 2 \
    --vnet-name "$VNET_NAME" \
    --subnet "$SUBNET_NAME" \
    --nsg "$NSG_NAME" \
    --admin-username "$ADMIN_USER" \
    "${SSH_ARGS[@]}" \
    --public-ip-sku Standard \
    -o none
fi

# --- Retrieve IPs ---
PRIMARY_PRIVATE_IP=$(az vm list-ip-addresses --resource-group "$RG" --name "$PRIMARY_VM" \
  --query '[0].virtualMachine.network.privateIpAddresses[0]' -o tsv)
SECONDARY_PRIVATE_IP=$(az vm list-ip-addresses --resource-group "$RG" --name "$SECONDARY_VM" \
  --query '[0].virtualMachine.network.privateIpAddresses[0]' -o tsv)
echo "  Primary IP:   $PRIMARY_PRIVATE_IP"
echo "  Secondary IP: $SECONDARY_PRIVATE_IP"

# --- Retrieve volume IQNs and portal ---
VOLUME_INFO=$(az elastic-san volume list \
  --elastic-san-name "$ESAN_NAME" \
  --volume-group-name "$VG_NAME" \
  --resource-group "$RG" \
  -o json)

PORTAL=$(echo "$VOLUME_INFO" | python3 -c "
import sys, json
vols = json.load(sys.stdin)
st = vols[0].get('storageTarget', {})
print(st.get('targetPortalHostname','') + ':' + str(st.get('targetPortalPort',3260)))
")

IQNS=$(echo "$VOLUME_INFO" | python3 -c "
import sys, json
vols = sorted(json.load(sys.stdin), key=lambda v: v['name'])
for v in vols:
    print(v.get('storageTarget',{}).get('targetIqn',''))
")
echo "  Portal: $PORTAL"

# =============================================
# PHASE 2: VM Configuration (via run-command)
# =============================================

echo ""
echo "Waiting for VMs to be ready for run-commands..."
for VM in "$PRIMARY_VM" "$SECONDARY_VM"; do
  for attempt in $(seq 1 12); do
    if az vm run-command invoke --resource-group "$RG" --name "$VM" \
        --command-id RunShellScript --scripts "echo ready" -o none 2>/dev/null; then
      echo "  $VM — ready"
      break
    fi
    if [[ $attempt -eq 12 ]]; then
      echo "  ERROR: $VM not responding after 2 minutes"
      exit 1
    fi
    echo "  $VM — not ready yet, retrying in 10s ($attempt/12)..."
    sleep 10
  done
done

echo ""
echo "=== [6/10] Installing packages on both VMs ==="
INSTALL_SCRIPT='
if command -v tdnf &>/dev/null; then
  tdnf install -y iscsi-initiator-utils sg3_utils golang
elif command -v apt-get &>/dev/null; then
  apt-get update -qq && apt-get install -y open-iscsi sg3-utils golang-go
elif command -v yum &>/dev/null; then
  yum install -y iscsi-initiator-utils sg3_utils golang
fi
systemctl enable --now iscsid
echo "PACKAGES OK"
'
echo "  Primary..."
run_on_vm "$PRIMARY_VM" "$INSTALL_SCRIPT"
echo "  Secondary..."
run_on_vm "$SECONDARY_VM" "$INSTALL_SCRIPT"

echo ""
echo "=== [7/10] Connecting iSCSI volumes on both VMs ==="
ISCSI_SCRIPT="
PORTAL='$PORTAL'
"
while IFS= read -r IQN; do
  [[ -z "$IQN" ]] && continue
  ISCSI_SCRIPT+="iscsiadm -m node --op=new -T '$IQN' -p \"\$PORTAL\" 2>/dev/null || true
iscsiadm -m node -T '$IQN' -p \"\$PORTAL\" --login 2>/dev/null || true
"
done <<< "$IQNS"
ISCSI_SCRIPT+='
sleep 5
COUNT=$(lsblk -d -o NAME,TRAN | grep -c iscsi || echo 0)
echo "Connected $COUNT iSCSI disks"
lsblk -d -o NAME,SIZE,TRAN | grep iscsi
'
echo "  Primary..."
run_on_vm "$PRIMARY_VM" "$ISCSI_SCRIPT"
echo "  Secondary..."
run_on_vm "$SECONDARY_VM" "$ISCSI_SCRIPT"

echo ""
echo "=== [8/10] Uploading source and building binaries ==="
PRIMARY_SRC_B64=$(base64 -w0 "$REPO_DIR/primary_main.go")
SECONDARY_SRC_B64=$(base64 -w0 "$REPO_DIR/secondary_main.go")

BUILD_SCRIPT="
export HOME=/root
export GOCACHE=/root/.cache/go-build
export GOEXPERIMENT=ms_nocgo_opensslcrypto
export CGO_ENABLED=0
mkdir -p /root/poc
echo '$PRIMARY_SRC_B64' | base64 -d > /root/poc/primary_main.go
echo '$SECONDARY_SRC_B64' | base64 -d > /root/poc/secondary_main.go
cd /root/poc
go build -o primary primary_main.go && go build -o secondary secondary_main.go && echo 'BUILD OK' || echo 'BUILD FAILED'
"
echo "  Primary..."
run_on_vm "$PRIMARY_VM" "$BUILD_SCRIPT"
echo "  Secondary..."
run_on_vm "$SECONDARY_VM" "$BUILD_SCRIPT"

echo ""
echo "=== [9/10] Installing systemd services ==="

ISCSI_SVC_B64=$(base64 -w0 "$REPO_DIR/systemd/iscsi-esan.service")
IPTABLES_SVC_B64=$(base64 -w0 "$REPO_DIR/systemd/iptables-poc.service")

PRIMARY_SVC_CONTENT=$(sed "s|<SECONDARY_IP>|$SECONDARY_PRIVATE_IP|g" "$REPO_DIR/systemd/zonedown-primary.service")
PRIMARY_SVC_B64=$(echo "$PRIMARY_SVC_CONTENT" | base64 -w0)
SECONDARY_SVC_B64=$(base64 -w0 "$REPO_DIR/systemd/zonedown-secondary.service")

# Write a self-contained install script that detects devices inside the VM
install_svc_script() {
  local role_svc_b64="$1"
  local role_svc_name="$2"
  cat <<REMOTE_EOF
#!/bin/bash
set -e
echo '$ISCSI_SVC_B64' | base64 -d > /etc/systemd/system/iscsi-esan.service
echo '$IPTABLES_SVC_B64' | base64 -d > /etc/systemd/system/iptables-poc.service
echo '$role_svc_b64' | base64 -d > /etc/systemd/system/${role_svc_name}.service
DEVICES=\$(lsblk -d -n -o NAME,TRAN | grep iscsi | awk '{print "/dev/" \$1}' | sort | tr '\n' ',' | sed 's/,\$//')
echo "Devices: \$DEVICES"
if [ -n "\$DEVICES" ]; then
  sed -i "s|--devices [^ ]*|--devices \$DEVICES|" /etc/systemd/system/${role_svc_name}.service
fi
mkdir -p /var/log/poc
systemctl daemon-reload
systemctl enable iscsi-esan iptables-poc ${role_svc_name}
echo "${role_svc_name} INSTALLED"
REMOTE_EOF
}

echo "  Primary..."
run_on_vm "$PRIMARY_VM" "$(install_svc_script "$PRIMARY_SVC_B64" "zonedown-primary")"

echo "  Secondary..."
run_on_vm "$SECONDARY_VM" "$(install_svc_script "$SECONDARY_SVC_B64" "zonedown-secondary")"

echo ""
echo "=== [10/10] Starting services ==="
SVC_START_PRIMARY='#!/bin/bash
systemctl start iscsi-esan iptables-poc zonedown-primary
sleep 2
systemctl is-active zonedown-primary && echo "PRIMARY RUNNING" || echo "PRIMARY FAILED"
'
SVC_START_SECONDARY='#!/bin/bash
systemctl start iscsi-esan iptables-poc zonedown-secondary
echo "SECONDARY STARTING (30s delay)"
sleep 35
systemctl is-active zonedown-secondary && echo "SECONDARY RUNNING" || echo "SECONDARY FAILED"
'
echo "  Primary..."
run_on_vm "$PRIMARY_VM" "$SVC_START_PRIMARY"
echo "  Secondary (30s startup delay)..."
run_on_vm "$SECONDARY_VM" "$SVC_START_SECONDARY"

echo ""
echo "============================================="
echo " Setup complete!"
echo "============================================="
echo ""
echo " Resource group:  $RG"
echo " Primary VM:      $PRIMARY_VM ($PRIMARY_PRIVATE_IP) — zone 1"
echo " Secondary VM:    $SECONDARY_VM ($SECONDARY_PRIVATE_IP) — zone 2"
echo " Elastic SAN:     $ESAN_NAME ($VOL_COUNT volumes)"
echo " Portal:          $PORTAL"
echo ""
echo " Monitor:"
echo "   ./scripts/monitor-remote.sh --name $NAME_PREFIX"
echo "   ./scripts/monitor-remote.sh --name $NAME_PREFIX --takeover"
echo ""
echo " Test failover:"
echo "   az vm deallocate -g $RG -n $PRIMARY_VM --no-wait"
echo ""
echo " Teardown:"
echo "   az group delete -n $RG --yes --no-wait"
