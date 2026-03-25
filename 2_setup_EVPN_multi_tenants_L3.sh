#!/usr/bin/env bash
set -euo pipefail

SUDO=""
[ "$EUID" -ne 0 ] && SUDO="sudo"

CLI=$(command -v podman || command -v docker)
KCLI=$(command -v kubectl || command -v oc)

############################################
# CONFIG
############################################
NUM_TENANTS=${1:-3}
TENANTS=(red blue green yellow orange purple)

FRR_VERSION="10.4.2"
FRR_IMAGE="quay.io/frrouting/frr:${FRR_VERSION}"
FRR_ASN=64512

# L3VNI range (One L3VNI per Tenant VRF)
BASE_L3VNI=30000 

# External FRR Container (Spine/GW)
FRR_CONTAINER_IP="192.168.111.3"
FRR_CONTAINER_GW="192.168.111.1"

############################################
# Helpers
############################################
node_ips() {
  $KCLI get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}'
}

############################################
# 1. FeatureGate & CNO Prep
############################################

echo "Checking FeatureGate status..."
CURRENT_FEATURESET=$(oc get featuregate cluster -o jsonpath='{.spec.featureSet}' || echo "None")

if [ "$CURRENT_FEATURESET" == "TechPreviewNoUpgrade" ]; then
    echo "TechPreviewNoUpgrade already enabled. Skipping patch."
else
    echo "Enabling TechPreviewNoUpgrade..."
    oc patch featuregate/cluster --patch '{"spec":{"featureSet":"TechPreviewNoUpgrade"}}' --type=merge
    echo "Waiting for MachineConfigPool to start updating nodes..."
    sleep 15m
    oc wait mcp master worker --for='condition=Updated=True' --timeout=20m
    oc wait mcp master worker --for='condition=Updating=False' --timeout=20m
    echo "Nodes rebooted and ready."
fi


echo "Patching CNO for EVPN (Local Gateway + Global Forwarding)..."
$KCLI patch Network.operator.openshift.io cluster --type=merge -p '
{
 "spec":{
  "additionalRoutingCapabilities":{"providers":["FRR"]},
  "defaultNetwork":{
   "ovnKubernetesConfig":{
    "routeAdvertisements":"Enabled",
    "gatewayConfig":{
     "routingViaHost":true,
     "ipForwarding":"Global"
    }
   }
  }
 }
}'

echo "Waiting for Network Operator stable..."
while true; do
    STATUS=$($KCLI get co network -o jsonpath='{range .status.conditions[?(@.type=="Available")]}{.status}{" "}{end}{range .status.conditions[?(@.type=="Progressing")]}{.status}{" "}{end}{range .status.conditions[?(@.type=="Degraded")]}{.status}{end}')
    [[ "$STATUS" == "True False False" ]] && break
    sleep 20
done

############################################
# 2. Upgrade frr-k8s to 10.4.2
############################################

echo "Upgrading frr-k8s to ${FRR_VERSION}..."
$KCLI patch Network.operator.openshift.io cluster --type merge -p '{"spec":{"managementState":"Unmanaged"}}'

$KCLI set image daemonset/frr-k8s -n openshift-frr-k8s \
    frr=${FRR_IMAGE} \
    reloader=${FRR_IMAGE}

$KCLI rollout status daemonset/frr-k8s -n openshift-frr-k8s --timeout=10m

############################################
# 3. apply frrConfiguration to OCP
############################################

echo "Detecting cluster IP stack type..."
SVC_NETWORK=$(oc get network.operator cluster -o jsonpath='{.spec.serviceNetwork}')
IS_V4=false
IS_V6=false
[[ "$SVC_NETWORK" =~ .*\..*\..* ]] && IS_V4=true
[[ "$SVC_NETWORK" =~ .*.*:.* ]] && IS_V6=true

if [ "$IS_V4" = true ] && [ "$IS_V6" = true ]; then
    STACK_TYPE="dualstack"
elif [ "$IS_V6" = true ]; then
    STACK_TYPE="ipv6single"
else
    STACK_TYPE="ipv4single"
fi
echo "Detected Stack: $STACK_TYPE"

create_frrconfig() {

# Apply stack-specific FRRConfiguration to enable per-node generation
CASE_FILE="./receive-filtered-singlestackv4.yaml"
[[ "$STACK_TYPE" == "ipv6single" ]] && CASE_FILE="./receive-filtered-singlestackv6.yaml"
[[ "$STACK_TYPE" == "dualstack" ]] && CASE_FILE="./receive-filtered-dualstack.yaml"
if [ -f "$CASE_FILE" ]; then
    oc apply -f "$CASE_FILE"
else
    echo "ERROR: FRRConfiguration file not found: $CASE_FILE"
    echo "Please create the FRRConfiguration YAML for stack type '$STACK_TYPE' before running this script."
    exit 1
fi

}


############################################
# 4. EVPN Infrastructure (VTEP & RouteAds)
############################################

create_evpn_infra() {
  echo "Creating VTEP and RouteAdvertisements..."
  $KCLI apply -f - <<EOF
apiVersion: k8s.ovn.org/v1
kind: VTEP
metadata:
  name: evpn-vtep
spec:
  mode: Unmanaged
  cidrs: 
  - 192.168.111.0/24
---
apiVersion: k8s.ovn.org/v1
kind: RouteAdvertisements
metadata:
  name: evpn-l3-ads
spec:
  nodeSelector: {}
  frrConfigurationSelector: {}
  networkSelectors:
    - networkSelectionType: ClusterUserDefinedNetworks
      clusterUserDefinedNetworkSelector:
        networkSelector:
          matchLabels: { evpn: "true" }
  targetVRF: auto
  advertisements: ["PodNetwork"]
EOF
}

############################################
# 5. External FRR & Agnhost Setup
############################################

generate_external_frr_conf() {
cat <<EOF
log stdout debugging
frr defaults traditional

$(for ((i=0;i<NUM_TENANTS;i++)); do
  T=${TENANTS[$i]}
  VNI=$((BASE_L3VNI+i))
  echo "vrf ${T}"
  echo " vni ${VNI}"
  echo "exit-vrf"
  echo "!"
done)

router bgp ${FRR_ASN}
 bgp router-id ${FRR_CONTAINER_IP}
 no bgp ebgp-requires-policy
 no bgp default ipv4-unicast

$(for ip in $(node_ips); do
  echo " neighbor $ip remote-as ${FRR_ASN}"
done)

 address-family ipv4 unicast
$(for ip in $(node_ips); do
  echo "  neighbor $ip activate"
  echo "  neighbor $ip route-reflector-client"
done)
 exit-address-family

 address-family l2vpn evpn
$(for ip in $(node_ips); do
  echo "  neighbor $ip activate"
  echo "  neighbor $ip route-reflector-client"
done)
  advertise-all-vni
  advertise ipv4 unicast
 exit-address-family

$(for ((i=0;i<NUM_TENANTS;i++)); do
  T=${TENANTS[$i]}
  VNI=$((BASE_L3VNI+i))
  RT="${FRR_ASN}:${VNI}"
  AGN_SUBNET="172.20.${i}.0/24"
cat <<EOT
router bgp ${FRR_ASN} vrf ${T}
 address-family ipv4 unicast
  network ${AGN_SUBNET}
 exit-address-family
 address-family l2vpn evpn
  rd ${RT}
  route-target import ${RT}
  route-target export ${RT}
  advertise ipv4 unicast
 exit-address-family
EOT
done)
EOF
}



deploy_external_frr() {
  echo "Deploying External FRR Container..."
  local frr_dir
  frr_dir=$(mktemp -d)

  generate_external_frr_conf > ${frr_dir}/frr.conf
  touch ${frr_dir}/vtysh.conf

  cat <<DEOF > ${frr_dir}/daemons
bgpd=yes
zebra=yes
DEOF

  chmod a+rw ${frr_dir}/*

  ############################################
  # Detect baremetal bridge for 192.168.111.0/24
  ############################################
  BRIDGE=""
  for br in $(ip link show type bridge 2>/dev/null | awk -F': ' '/^[0-9]/{print $2}'); do
      if ip -4 addr show "$br" 2>/dev/null | grep -q "192\.168\.111\."; then
          BRIDGE="$br"
          break
      fi
  done

  if [ -z "$BRIDGE" ]; then
      echo "ERROR: No bridge found carrying 192.168.111.0/24."
      echo "Expected a baremetal bridge (e.g. ostestbm, baremetal) with an IP in 192.168.111.0/24."
      echo "Available bridges:"
      ip link show type bridge 2>/dev/null | awk -F': ' '/^[0-9]/{print "  " $2}'
      exit 1
  fi
  echo "Found baremetal bridge: $BRIDGE"

  ############################################
  # Start FRR container
  ############################################
  $CLI rm -f frr 2>/dev/null || true
  $CLI network rm -f ${BRIDGE}_net 2>/dev/null || true

  $CLI network create \
      --driver bridge \
      --ipam-driver=none \
      --opt com.docker.network.bridge.name=${BRIDGE} \
      ${BRIDGE}_net

  ############################################
  # Start FRR container on baremetal bridge
  ############################################
  $CLI run -d --privileged \
      --ulimit core=-1 \
      --network ${BRIDGE}_net \
      --name frr \
      --volume ${frr_dir}:/etc/frr \
      ${FRR_IMAGE}

  $CLI exec frr sysctl -w net.ipv6.conf.all.forwarding=1
  $CLI exec frr ip address add dev eth0 ${FRR_CONTAINER_IP}/24
  $CLI exec frr ip route add default dev eth0 via ${FRR_CONTAINER_GW}

  ############################################
  # Create tenant VRFs + VXLAN + agnhost
  ############################################
  for ((i=0;i<NUM_TENANTS;i++)); do
    T=${TENANTS[$i]}
    VNI=$((BASE_L3VNI+i))
    TABLE=$((100+i))

    AGN_GW_IP="172.20.${i}.1"
    AGN_HOST_IP="172.20.${i}.100"

    ############################################
    # 1. Create VRF
    ############################################
    echo "Creating VRF ${T}..."
    $CLI exec frr ip link add ${T} type vrf table ${TABLE}
    $CLI exec frr ip link set ${T} up

    ############################################
    # 2. Deploy agnhost container
    ############################################
    deploy_agnhost_container "agnhost_${T}" "$AGN_HOST_IP"

    ############################################
    # 3. Connect FRR to tenant network
    ############################################
    NET="agnhost_${T}_net"
    echo "Connecting FRR to ${NET}..."

    BEFORE_IFS=$($CLI exec frr ip -o link show | awk -F': ' '{print $2}')

    echo "Connecting FRR to ${NET} with IP ${AGN_GW_IP}..."
    $CLI network connect --ip "${AGN_GW_IP}" "$NET" frr

    sleep 1

    AFTER_IFS=$($CLI exec frr ip -o link show | awk -F': ' '{print $2}')

    IFACE=$(comm -13 <(echo "$BEFORE_IFS" | sort) <(echo "$AFTER_IFS" | sort) | head -n1)
    IFACE="${IFACE%%@*}"

    if [ -z "$IFACE" ]; then
        echo "ERROR: could not detect new interface for tenant $T"
        exit 1
    fi

    echo "Found interface $IFACE"

    ############################################
    # 4. Attach interface to VRF
    ############################################
    $CLI exec frr ip link set dev "$IFACE" master ${T}
    $CLI exec frr ip link set dev "$IFACE" up

    ############################################
    # 5. Create bridge + VXLAN for symmetric IRB
    ############################################
    echo "Creating bridge br-${T} + VXLAN vxl-${VNI} for L3VNI"

    $CLI exec frr ip link add br-${T} type bridge
    $CLI exec frr ip link set br-${T} addrgenmode none
    $CLI exec frr ip link set br-${T} master ${T}
    $CLI exec frr ip link set br-${T} up

    $CLI exec frr ip link add vxl-${VNI} \
        type vxlan id ${VNI} \
        local ${FRR_CONTAINER_IP} \
        dstport 4789 \
        nolearning

    $CLI exec frr ip link set vxl-${VNI} addrgenmode none
    $CLI exec frr ip link set vxl-${VNI} master br-${T}
    $CLI exec frr ip link set vxl-${VNI} up

    ############################################
    # 6. Set agnhost default route via FRR
    ############################################
    echo "Setting agnhost_${T} default route via FRR (${AGN_GW_IP})..."
    $CLI exec "agnhost_${T}" ip route replace default via "${AGN_GW_IP}" dev eth0

  done
}


DUMMY=0
deploy_agnhost_container() {
    local name=$1
    local ip_addr=$2
    local net="${name}_net"

    local subnet="${ip_addr%.*}.0/24"

    echo "Creating network $net ($subnet)..."

    $CLI rm -f "$name" 2>/dev/null || true
    $CLI network rm -f "$net" 2>/dev/null || true

    $CLI network create \
        --driver bridge \
        --subnet "$subnet" \
        --gateway "${ip_addr%.*}.254" \
        "$net"

    echo "Starting container $name..."
    $CLI run -d --privileged \
        --name "$name" \
        --hostname "$name" \
        --network "$net" \
        --ip "$ip_addr" \
        registry.k8s.io/e2e-test-images/agnhost:2.40 netexec --http-port=8000

    local actual_ip
    actual_ip=$($CLI inspect -f "{{.NetworkSettings.Networks.${net}.IPAddress}}" "$name")
    echo "Successfully deployed $name at $actual_ip"
}

############################################
# 6. Create L3 Tenants
############################################

create_l3_tenants() {
for ((i=0;i<NUM_TENANTS;i++)); do
  T=${TENANTS[$i]}
  NS="l3vpn-${T}"
  VNI=$((BASE_L3VNI+i))

  cat <<EOF | $KCLI apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ${NS}
  labels:
    network: "${T}"
    k8s.ovn.org/primary-user-defined-network: "${T}-evpn"
---
apiVersion: k8s.ovn.org/v1
kind: ClusterUserDefinedNetwork
metadata:
  name: ${T}-evpn
  labels:
    evpn: "true"
spec:
  namespaceSelector:
    matchLabels:
      network: "${T}"

  network:
    topology: Layer3
    transport: EVPN

    layer3:
      role: Primary
      subnets:
        - cidr: "10.${i}.0.0/16"
          hostSubnet: 24

    evpn:
      vtep: evpn-vtep
      ipVRF:
        vni: ${VNI}
        routeTarget: "${FRR_ASN}:${VNI}"
EOF
done
}


############################################
# 7. Deploy Workloads
############################################

deploy_workloads() {
  for ((i=0;i<NUM_TENANTS;i++)); do
    local T=${TENANTS[$i]}
    local NS="l3vpn-${T}"

    echo "Deploying workload in ${NS}..."
    $KCLI -n ${NS} create deployment nettools \
        --image docker.io/nicolaka/netshoot \
        -- sleep infinity || true

    $KCLI -n ${NS} scale deploy nettools --replicas=2

    $KCLI -n ${NS} rollout status deployment/nettools --timeout=2m
  done
}

############################################
# MAIN
############################################

deploy_external_frr
create_frrconfig
create_evpn_infra
create_l3_tenants
deploy_workloads

echo "EVPN Multi-tenant L3VPN Setup complete. "
