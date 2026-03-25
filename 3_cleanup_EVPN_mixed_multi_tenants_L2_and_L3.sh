#!/usr/bin/env bash
set -uo pipefail
# NOTE: not using -e so cleanup continues even if individual deletes fail

CLI=$(command -v podman || command -v docker)
KCLI=$(command -v kubectl || command -v oc)

############################################
# CONFIG (must match setup script)
############################################

L2_TENANTS=(red blue)
L3_TENANTS=(orange green)

############################################
# Preserved (NOT cleaned up):
#   - FeatureGate TechPreviewNoUpgrade
#   - CNO: additionalRoutingCapabilities,
#          routeAdvertisements, LGW, Global
#   - frr-k8s 10.4.2 upgrade
############################################

echo "============================================"
echo "Cleaning up mixed L2+L3 EVPN resources"
echo "============================================"
echo ""
echo "Keeping: FeatureGate, CNO EVPN config, frr-k8s"
echo ""

############################################
# 1. Delete workloads
############################################

echo "--- Deleting workloads ---"

for T in "${L2_TENANTS[@]}"; do
    NS="l2vpn-${T}"
    echo "Deleting deployment in ${NS}..."
    $KCLI -n "${NS}" delete deployment nettools --ignore-not-found 2>/dev/null || true
done

for T in "${L3_TENANTS[@]}"; do
    NS="l3vpn-${T}"
    echo "Deleting deployment in ${NS}..."
    $KCLI -n "${NS}" delete deployment nettools --ignore-not-found 2>/dev/null || true
done

echo "Waiting for pods to terminate..."
for T in "${L2_TENANTS[@]}"; do
    $KCLI -n "l2vpn-${T}" wait --for=delete pod --all --timeout=60s 2>/dev/null || true
done
for T in "${L3_TENANTS[@]}"; do
    $KCLI -n "l3vpn-${T}" wait --for=delete pod --all --timeout=60s 2>/dev/null || true
done

############################################
# 2. Delete CUDNs (before namespaces)
############################################

echo ""
echo "--- Deleting ClusterUserDefinedNetworks ---"

for T in "${L2_TENANTS[@]}" "${L3_TENANTS[@]}"; do
    echo "Deleting CUDN ${T}-evpn..."
    $KCLI delete clusteruserdefinednetwork "${T}-evpn" --ignore-not-found 2>/dev/null || true
done

############################################
# 3. Delete namespaces
############################################

echo ""
echo "--- Deleting namespaces ---"

for T in "${L2_TENANTS[@]}"; do
    echo "Deleting namespace l2vpn-${T}..."
    $KCLI delete namespace "l2vpn-${T}" --ignore-not-found 2>/dev/null || true
done

for T in "${L3_TENANTS[@]}"; do
    echo "Deleting namespace l3vpn-${T}..."
    $KCLI delete namespace "l3vpn-${T}" --ignore-not-found 2>/dev/null || true
done

############################################
# 4. Delete RouteAdvertisements & VTEP
############################################

echo ""
echo "--- Deleting EVPN control plane ---"

echo "Deleting RouteAdvertisements evpn-ads..."
$KCLI delete routeadvertisements evpn-ads --ignore-not-found 2>/dev/null || true

echo "Deleting VTEP evpn-vtep..."
$KCLI delete vtep evpn-vtep --ignore-not-found 2>/dev/null || true

############################################
# 5. Delete FRRConfiguration
############################################

echo ""
echo "--- Deleting FRRConfiguration ---"

for f in ./receive-filtered-singlestackv4.yaml \
         ./receive-filtered-singlestackv6.yaml \
         ./receive-filtered-dualstack.yaml; do
    if [ -f "$f" ]; then
        echo "Deleting FRRConfiguration from $f..."
        oc delete -f "$f" --ignore-not-found 2>/dev/null || true
    fi
done

############################################
# 6. Remove external containers & networks
############################################

echo ""
echo "--- Removing external containers ---"

for T in "${L2_TENANTS[@]}" "${L3_TENANTS[@]}"; do
    NAME="agnhost_${T}"
    NET="${NAME}_net"

    echo "Stopping ${NAME}..."
    $CLI rm -f "${NAME}" 2>/dev/null || true

    echo "Disconnecting FRR from ${NET}..."
    $CLI network disconnect "${NET}" frr 2>/dev/null || true

    echo "Removing network ${NET}..."
    $CLI network rm -f "${NET}" 2>/dev/null || true
done

echo "Stopping FRR container..."
$CLI rm -f frr 2>/dev/null || true

# Detect and remove the baremetal bridge network
for br in $(ip link show type bridge 2>/dev/null | awk -F': ' '/^[0-9]/{print $2}'); do
    if ip -4 addr show "$br" 2>/dev/null | grep -q "192\.168\.111\."; then
        NET="${br}_net"
        echo "Removing bridge network ${NET}..."
        $CLI network rm -f "${NET}" 2>/dev/null || true
        break
    fi
done

############################################
# 7. Wait for namespace deletion
############################################

echo ""
echo "--- Waiting for namespaces to be fully removed ---"

for T in "${L2_TENANTS[@]}"; do
    NS="l2vpn-${T}"
    if $KCLI get namespace "${NS}" &>/dev/null; then
        echo "Waiting for ${NS} to terminate..."
        $KCLI wait --for=delete namespace "${NS}" --timeout=120s 2>/dev/null || true
    fi
done

for T in "${L3_TENANTS[@]}"; do
    NS="l3vpn-${T}"
    if $KCLI get namespace "${NS}" &>/dev/null; then
        echo "Waiting for ${NS} to terminate..."
        $KCLI wait --for=delete namespace "${NS}" --timeout=120s 2>/dev/null || true
    fi
done

echo ""
echo "============================================"
echo "Cleanup complete"
echo "============================================"
echo ""
echo "Preserved:"
echo "  - FeatureGate: TechPreviewNoUpgrade"
echo "  - CNO: FRR routing, routeAdvertisements, LGW, Global forwarding"
echo "  - frr-k8s: 10.4.2"
echo ""
echo "Removed:"
echo "  - Workloads (nettools deployments)"
echo "  - CUDNs (red-evpn, blue-evpn, orange-evpn, green-evpn)"
echo "  - Namespaces (l2vpn-red, l2vpn-blue, l3vpn-orange, l3vpn-green)"
echo "  - RouteAdvertisements (evpn-ads)"
echo "  - VTEP (evpn-vtep)"
echo "  - FRRConfiguration"
echo "  - External FRR container"
echo "  - Agnhost containers (red, blue, orange, green)"
echo "  - Podman/Docker networks"
