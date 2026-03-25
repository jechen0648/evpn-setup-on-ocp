#!/usr/bin/env bash
set -uo pipefail

SUDO=""
[ "$EUID" -ne 0 ] && SUDO="sudo"

CLI=$(command -v podman || command -v docker)
KCLI=$(command -v kubectl || command -v oc)

############################################
# CONFIG (Must match setup script)
############################################
NUM_TENANTS=${1:-3}
TENANTS=(red blue green yellow orange purple)
BASE_L3VNI=30000

echo "Starting L3 EVPN Cleanup..."

############################################
# 1. Delete Workload Pods FIRST
############################################
echo "Deleting tenant workload pods..."

for ((i=0;i<NUM_TENANTS;i++)); do
    T=${TENANTS[$i]}
    NS="l3vpn-${T}"

    echo "Cleaning pods in namespace ${NS}"

    # Delete deployment and all pods
    $KCLI delete deployment nettools -n $NS --ignore-not-found

    $KCLI delete pod --all -n "${NS}" --ignore-not-found=true

    # Wait until pods disappear
    while true; do
        PODS=$($KCLI get pods -n "${NS}" --no-headers 2>/dev/null | wc -l || echo 0)
        [[ "$PODS" == "0" ]] && break
        sleep 2
    done
done

############################################
# 2. Delete CUDNs
############################################
echo "Deleting ClusterUserDefinedNetworks..."

for ((i=0;i<NUM_TENANTS;i++)); do
    T=${TENANTS[$i]}
    $KCLI delete clusteruserdefinednetwork "${T}-evpn" --ignore-not-found=true
done

############################################
# 3. Delete Namespaces
############################################
echo "Deleting tenant namespaces..."

for ((i=0;i<NUM_TENANTS;i++)); do
    T=${TENANTS[$i]}
    NS="l3vpn-${T}"
    $KCLI delete namespace "${NS}" --ignore-not-found=true --wait=false
done

############################################
# 4. Remove EVPN Infrastructure
############################################
echo "Removing VTEP and RouteAdvertisements..."

$KCLI delete vtep evpn-vtep --ignore-not-found=true
$KCLI delete routeadvertisements evpn-l3-ads --ignore-not-found=true

echo "Removing FRRConfiguration..."
$KCLI delete frrconfiguration receive-filtered -n openshift-frr-k8s --ignore-not-found=true

############################################
# 5. Stop External FRR Container
############################################
echo "Stopping External FRR Container..."
$CLI rm -f frr >/dev/null 2>&1 || true

############################################
# 6. Cleanup Linux VRF / VXLAN Interfaces
############################################
echo "Cleaning Linux VRFs and VXLAN interfaces..."

for ((i=0;i<NUM_TENANTS;i++)); do
    T=${TENANTS[$i]}
    VNI=$((BASE_L3VNI+i))

    if ip link show "vxl-${VNI}" >/dev/null 2>&1; then
        $SUDO ip link delete "vxl-${VNI}" || true
    fi

    if ip link show "${T}" >/dev/null 2>&1; then
        $SUDO ip link delete "${T}" || true
    fi
done

############################################
# 7. Revert CNO (Optional)
############################################
# Note: Reverting FeatureGates or CNO patches is often skipped in labs 
# because it triggers a full node reboot. 
# Uncomment the block below if you want a total reset.

# echo "Reverting CNO to default (Warning: This may trigger reboots)..."
# $KCLI patch Network.operator.openshift.io cluster --type=merge -p '
# {
#  "spec":{
#   "managementState":"Managed",
#   "additionalRoutingCapabilities":{"providers":[]},
#   "defaultNetwork":{
#    "ovnKubernetesConfig":{
#     "routeAdvertisements":"Disabled",
#     "gatewayConfig":{
#      "routingViaHost":false,
#      "ipForwarding":"Disable"
#     }
#    }
#   }
#  }
# }'

echo "Cleanup complete."
