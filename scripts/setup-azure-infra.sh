#!/bin/bash
#
# Creates the complete Azure infrastructure for the zone-down failover POC:
#   - Resource group
#   - VNet, subnet, and NSG with internal traffic rules
#   - Elastic SAN with Premium_ZRS, volume group, and 10 iSCSI volumes
#   - Two VMs in different availability zones
#
# Prerequisites:
#   - Azure CLI logged in with appropriate permissions
#   - An SSH public key at ~/.ssh/id_rsa.pub (or set SSH_PUB_KEY below)
#
# Usage:
#   ./setup-azure-infra.sh --name <prefix>
#   ./setup-azure-infra.sh --name jbhushan --location westus2 --vm-size Standard_D4s_v5
#   ./setup-azure-infra.sh   (uses defaults)
#
# All resource names are derived from the --name prefix.
#
set -euo pipefail

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
      echo "Usage: $0 [--name PREFIX] [--location REGION] [--vol-count N] [--vm-size SIZE] ..."
      echo ""
      echo "Options:"
      echo "  --name PREFIX       Name prefix for all resources (default: jbhushan)"
      echo "  --location REGION   Azure region (default: eastus2)"
      echo "  --vol-count N       Number of volumes (default: 10)"
      echo "  --vol-size-gib N    Size of each volume in GiB (default: 1)"
      echo "  --esan-size-tib N   Elastic SAN base size in TiB (default: 1)"
      echo "  --vnet-prefix CIDR  VNet address space (default: 10.163.0.0/24)"
      echo "  --vm-size SIZE      VM SKU (default: Standard_E8ds_v6)"
      echo "  --vm-image IMAGE    VM image URN (default: Azure Linux 3)"
      echo "  --admin-user USER   VM admin username (default: client)"
      echo "  --ssh-key PATH      Path to SSH public key (default: ~/.ssh/id_rsa.pub)"
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

# -----------------------------------------------

echo "============================================"
echo " Zone-Down Failover POC — Infrastructure"
echo "============================================"
echo ""

# --- Resource Group ---
echo "=== 1/7 Resource group ==="
if az group show --name "$RG" -o none 2>/dev/null; then
  echo "  $RG already exists — reusing"
else
  az group create --name "$RG" --location "$LOCATION" -o none
  echo "  $RG created ($LOCATION)"
fi

# --- Networking ---
echo ""
echo "=== 2/7 VNet, subnet, and NSG ==="

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

# --- Elastic SAN ---
echo ""
echo "=== 3/7 Elastic SAN ==="
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

echo ""
echo "=== 4/7 Volume group ==="
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
echo "=== 5/7 Volumes ==="
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

# --- VMs ---
echo ""
echo "=== 6/7 VMs ==="

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

echo ""
echo "=== 7/7 Retrieving IP addresses ==="
az vm list-ip-addresses --resource-group "$RG" -o table

# --- Summary ---
echo ""
echo "============================================"
echo " Infrastructure setup complete"
echo "============================================"
echo ""
echo "Volume IQNs and portals:"
az elastic-san volume list \
  --elastic-san-name "$ESAN_NAME" \
  --volume-group-name "$VG_NAME" \
  --resource-group "$RG" \
  -o json | python3 -c "
import sys, json
vols = sorted(json.load(sys.stdin), key=lambda v: v['name'])
portal = ''
for v in vols:
    st = v.get('storageTarget', {})
    portal = st.get('targetPortalHostname','') + ':' + str(st.get('targetPortalPort',3260))
    print(f\"  {v['name']}  {st.get('targetIqn')}\")
print()
print(f'Portal: {portal}')
"

echo ""
echo "Next steps:"
echo "  1. Copy this repo to both VMs"
echo "  2. Run on primary VM:"
echo "     ./scripts/setup-vm.sh --role primary --remote-ip <SECONDARY_PRIVATE_IP> --portal <PORTAL>"
echo "  3. Run on secondary VM:"
echo "     ./scripts/setup-vm.sh --role secondary --portal <PORTAL>"
echo "  4. Start services:"
echo "     systemctl start iscsi-esan iptables-poc zonedown-primary    # on primary"
echo "     systemctl start iscsi-esan iptables-poc zonedown-secondary  # on secondary"
