#!/usr/bin/env bash
set -euo pipefail
set -x

############################################
# CONFIG
############################################

TENANTS=(red blue green yellow orange purple)

FRR_CONTAINER="frr"

BRIDGE="sdn150bm"
CONTAINER_NET="${BRIDGE}_net"

############################################
# Container CLI detection
############################################

CLI="podman"
command -v podman >/dev/null || CLI="docker"

############################################
# 1 Remove workloads, tenant networks and namespaces
############################################
NUM_TENANTS=${1:-3}

for ((i=0;i<NUM_TENANTS;i++))
do

TENANT=${TENANTS[$i]}
NS="l2vpn-${TENANT}"

kubectl delete deployment nettools -n $NS --ignore-not-found
kubectl delete pod --all -n $NS --ignore-not-found

kubectl delete clusteruserdefinednetwork $TENANT-evpn --ignore-not-found

kubectl delete namespace $NS --ignore-not-found

done

############################################
# 4 Delete EVPN control plane resources
############################################

kubectl delete routeadvertisements evpn-routes --ignore-not-found

kubectl delete vtep evpn-vtep --ignore-not-found

kubectl delete frrconfiguration receive-filtered \
-n openshift-frr-k8s \
--ignore-not-found

############################################
# 5 Remove external FRR container
############################################

$CLI rm -f $FRR_CONTAINER || true

############################################
# 6 Remove lab container network
############################################

$CLI network rm $CONTAINER_NET || true

############################################
# 7 Optional iptables cleanup
############################################

sudo iptables -t nat -D POSTROUTING -s 10.128.0.0/14 ! -d 192.168.111.0/24 -j MASQUERADE || true

sudo iptables -D FORWARD -s 10.128.0.0/14 -i ${BRIDGE} -j ACCEPT || true

sudo iptables -D FORWARD -d 10.128.0.0/14 -o ${BRIDGE} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT || true

############################################
# 8 Final status
############################################

echo
echo "======================================"
echo "EVPN multi-tenant L2 EVPN cleanup complete"
echo "======================================"
echo
echo "Preserved cluster configuration:"
echo "  FeatureGate: TechPreviewNoUpgrade"
echo "  CNO routingViaHost: true"
echo "  CNO ipForwarding: Global"
echo "  CNO RouteAdvertisements: Enabled"
echo "  additionalRoutingCapabilities: FRR"
echo
