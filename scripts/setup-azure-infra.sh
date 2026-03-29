#!/bin/bash
#
# Creates the Azure infrastructure for the zone-down failover POC:
#   - Resource group
#   - Elastic SAN with Premium_ZRS
#   - Volume group and 10 iSCSI volumes
#   - Two VMs in different availability zones
#
# Prerequisites: Azure CLI logged in with appropriate permissions.
#
# Usage: ./setup-azure-infra.sh
#
set -euo pipefail

RG="jbhushan-zone-down-poc-rg"
LOCATION="eastus2"
ESAN_NAME="jbhushan-zrs-esan"
VG_NAME="jbhushan-zrs-vg"
VOL_PREFIX="jbhushan-zrs-vol"
VOL_COUNT=10
VOL_SIZE_GIB=1
ESAN_BASE_SIZE_TIB=1
PRIMARY_VM="jbhushan-zrs-primary"
SECONDARY_VM="jbhushan-zrs-secondary"

echo "=== Creating resource group ==="
az group create --name "$RG" --location "$LOCATION" -o none

echo "=== Creating Elastic SAN (Premium_ZRS, ${ESAN_BASE_SIZE_TIB} TiB) ==="
az elastic-san create \
  --elastic-san-name "$ESAN_NAME" \
  --resource-group "$RG" \
  --location "$LOCATION" \
  --base-size-tib "$ESAN_BASE_SIZE_TIB" \
  --extended-capacity-size-tib 0 \
  --sku Premium_ZRS \
  -o none

echo "=== Creating volume group ==="
az elastic-san volume-group create \
  --elastic-san-name "$ESAN_NAME" \
  --volume-group-name "$VG_NAME" \
  --resource-group "$RG" \
  -o none

echo "=== Creating ${VOL_COUNT} volumes (${VOL_SIZE_GIB} GiB each) ==="
for i in $(seq -w 1 "$VOL_COUNT"); do
  echo "  Creating ${VOL_PREFIX}-$i..."
  az elastic-san volume create \
    --elastic-san-name "$ESAN_NAME" \
    --volume-group-name "$VG_NAME" \
    --name "${VOL_PREFIX}-$i" \
    --size-gib "$VOL_SIZE_GIB" \
    --resource-group "$RG" \
    -o none
done

echo ""
echo "=== Volume IQNs and portals ==="
az elastic-san volume list \
  --elastic-san-name "$ESAN_NAME" \
  --volume-group-name "$VG_NAME" \
  --resource-group "$RG" \
  -o json | python3 -c "
import sys, json
vols = sorted(json.load(sys.stdin), key=lambda v: v['name'])
for v in vols:
    st = v.get('storageTarget', {})
    print(f\"{v['name']}  {st.get('targetIqn')}  {st.get('targetPortalHostname')}:{st.get('targetPortalPort')}\")
"

echo ""
echo "=== Infrastructure setup complete ==="
echo ""
echo "Next steps:"
echo "  1. Create two VMs (zone 1 and zone 2) in resource group $RG"
echo "  2. Run setup-vm.sh on each VM to connect iSCSI volumes and install services"
