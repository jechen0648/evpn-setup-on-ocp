#!/usr/bin/env bash
set -euo pipefail
set -x

SUDO=
if [ "$EUID" -ne 0 ]; then
  SUDO="sudo"
fi

CLI="$SUDO podman"
if ! command -v "podman"; then
    CLI="$SUDO docker"
fi
echo "Container CLI is: $CLI"

KCLI="kubectl"
if ! command -v $KCLI; then
    KCLI="oc"
fi

IP="$SUDO ip"
IPTABLES="$SUDO iptables"
IP6TABLES="$SUDO ip6tables"


############################################
# CONFIG
############################################

NUM_TENANTS=${1:-3}

TENANTS=(red blue green yellow orange purple)

FRR_VERSION="10.4.2"
FRR_IMAGE="quay.io/frrouting/frr:${FRR_VERSION}"

FRR_ASN=64512

BASE_VNI=20100
BASE_IP_VNI=20200

FRR_CONTAINER_IP="192.168.111.3"
FRR_CONTAINER_GW="192.168.111.1"

BRIDGE=""
CONTAINER_NET=""

############################################
# Helper
############################################

node_ips() {
oc get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}'
}

############################################
# 1 FeatureGate
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

############################################
# 2 Patch CNO for EVPN
############################################

echo "Patching CNO EVPN configuration..."

oc patch Network.operator.openshift.io cluster --type=merge -p '

{
 "spec":{
  "additionalRoutingCapabilities":{
   "providers":["FRR"]
  },
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
}
'

echo "Waiting for Network Operator stable..."

while true
do

STATUS=$(oc get co network -o jsonpath='{range .status.conditions[?(@.type=="Available")]}{.status}{" "}{end}{range .status.conditions[?(@.type=="Progressing")]}{.status}{" "}{end}{range .status.conditions[?(@.type=="Degraded")]}{.status}{end}')

[[ "$STATUS" == "True False False" ]] && break

sleep 20

done

############################################
# 3 Upgrade frr-k8s
############################################

echo "Upgrading frr-k8s..."

oc patch Network.operator.openshift.io cluster \
--type merge \
-p '{"spec":{"managementState":"Unmanaged"}}'

oc set image daemonset/frr-k8s \
-n openshift-frr-k8s \
frr=${FRR_IMAGE} \
reloader=${FRR_IMAGE}

oc rollout status daemonset/frr-k8s -n openshift-frr-k8s --timeout=10m

############################################
# 4 Generate FRR Config
############################################

generate_frr_config() {

cat <<EOF
log stdout debugging
frr defaults traditional
EOF

for ((i=0;i<NUM_TENANTS;i++)); do
  T=${TENANTS[$i]}
  IP_VNI=$((BASE_IP_VNI+i))
  echo "vrf ${T}"
  echo " vni ${IP_VNI}"
  echo "exit-vrf"
  echo "!"
done

cat <<EOF
router bgp ${FRR_ASN}
 bgp router-id ${FRR_CONTAINER_IP}
 no bgp ebgp-requires-policy
 no bgp default ipv4-unicast
EOF

for ip in $(node_ips); do
echo " neighbor $ip remote-as ${FRR_ASN}"
done

echo
echo " address-family ipv4 unicast"

for ip in $(node_ips); do
echo "  neighbor $ip activate"
echo "  neighbor $ip route-reflector-client"
done

echo " exit-address-family"
echo
echo " address-family l2vpn evpn"

for ip in $(node_ips); do
echo "  neighbor $ip activate"
echo "  neighbor $ip route-reflector-client"
done

echo "  advertise-all-vni"

for ((i=0;i<NUM_TENANTS;i++)); do
  MAC_VNI=$((BASE_VNI+i))
  RT_MAC="${FRR_ASN}:${MAC_VNI}"
cat <<EOF
  vni ${MAC_VNI}
   rd ${RT_MAC}
   route-target import ${RT_MAC}
   route-target export ${RT_MAC}
  exit-vni
EOF
done

echo " exit-address-family"
echo "exit"
echo "!"

for ((i=0;i<NUM_TENANTS;i++)); do
  T=${TENANTS[$i]}
  IP_VNI=$((BASE_IP_VNI+i))
  RT_IP="${FRR_ASN}:${IP_VNI}"
cat <<EOT
router bgp ${FRR_ASN} vrf ${T}
 address-family l2vpn evpn
  rd ${RT_IP}
  route-target import ${RT_IP}
  route-target export ${RT_IP}
  advertise ipv4 unicast
 exit-address-family
EOT
done

}

############################################
# 5 Start External FRR
############################################

deploy_frr_external_container() {

  echo "Deploying FRR external container..."

  local frr_config=$(mktemp -d)

  generate_frr_config > ${frr_config}/frr.conf
  touch ${frr_config}/vtysh.conf

  cat <<EOF > ${frr_config}/daemons
bgpd=yes
zebra=yes
EOF

  chmod a+rw ${frr_config}/*

  # Auto-detect baremetal bridge carrying 192.168.111.0/24
  BRIDGE=""
  for br in $(ip link show type bridge 2>/dev/null | awk -F': ' '/^[0-9]/{print $2}'); do
      if ip -4 addr show "$br" 2>/dev/null | grep -q "192\.168\.111\."; then
          BRIDGE="$br"
          break
      fi
  done
  if [ -z "$BRIDGE" ]; then
      echo "ERROR: No bridge found carrying 192.168.111.0/24."
      echo "Available bridges:"
      ip link show type bridge 2>/dev/null | awk -F': ' '/^[0-9]/{print "  " $2}'
      exit 1
  fi
  echo "Found baremetal bridge: $BRIDGE"
  CONTAINER_NET="${BRIDGE}_net"

  $CLI rm -f frr || true
  $CLI network rm -f ${CONTAINER_NET} || true

  $CLI network create \
    --driver bridge \
    --ipam-driver=none \
    --opt com.docker.network.bridge.name=${BRIDGE} \
    ${CONTAINER_NET}

  $CLI run -d \
    --privileged \
    --ulimit core=-1 \
    --network ${CONTAINER_NET} \
    --name frr \
    --volume ${frr_config}:/etc/frr \
    ${FRR_IMAGE}

  $CLI exec frr sysctl -w net.ipv6.conf.all.forwarding=1

  $CLI exec frr ip address add dev eth0 ${FRR_CONTAINER_IP}/24
  $CLI exec frr ip route add default dev eth0 via ${FRR_CONTAINER_GW}

  ############################################
  # Create EVPN bridge + VXLAN (SVD mode)
  ############################################
  echo "Creating EVPN bridge and VXLAN (SVD mode)..."

  $CLI exec frr ip link add br-evpn type bridge vlan_filtering 1 vlan_default_pvid 0
  $CLI exec frr ip link set br-evpn addrgenmode none

  $CLI exec frr ip link add vx-evpn type vxlan \
      dstport 4789 local ${FRR_CONTAINER_IP} nolearning external vnifilter
  $CLI exec frr ip link set vx-evpn addrgenmode none
  $CLI exec frr ip link set vx-evpn master br-evpn

  $CLI exec frr ip link set br-evpn up
  $CLI exec frr ip link set vx-evpn up

  $CLI exec frr bridge link set dev vx-evpn vlan_tunnel on neigh_suppress on learning off

  ############################################
  # Per-tenant: agnhost + MAC-VRF + IP-VRF
  ############################################
  for ((i=0;i<NUM_TENANTS;i++)); do
    T=${TENANTS[$i]}
    MAC_VNI=$((BASE_VNI+i))
    IP_VNI=$((BASE_IP_VNI+i))
    MAC_VID=$((100+i*2))
    IP_VID=$((100+i*2+1))

    AGNHOST_IP="10.${i}.0.250"

    echo "=== Tenant ${T}: MAC-VRF VNI=${MAC_VNI} VID=${MAC_VID}, IP-VRF VNI=${IP_VNI} VID=${IP_VID} ==="

    ############################################
    # 1. Deploy agnhost on CUDN subnet
    ############################################
    deploy_agnhost_container "agnhost_${T}" "${AGNHOST_IP}"

    ############################################
    # 2. Connect FRR to agnhost network
    ############################################
    NET="agnhost_${T}_net"
    echo "Connecting FRR to ${NET}..."

    BEFORE_IFS=$($CLI exec frr ip -o link show | awk -F': ' '{print $2}')

    $CLI network connect "$NET" frr

    sleep 1

    AFTER_IFS=$($CLI exec frr ip -o link show | awk -F': ' '{print $2}')

    IFACE=$(comm -13 <(echo "$BEFORE_IFS" | sort) <(echo "$AFTER_IFS" | sort) | head -n1)
    IFACE="${IFACE%%@*}"

    if [ -z "$IFACE" ]; then
        echo "ERROR: could not detect new interface for tenant $T"
        exit 1
    fi
    echo "Found FRR interface $IFACE for tenant $T"

    ############################################
    # 3. Move FRR interface to bridge as
    #    MAC-VRF access port
    ############################################
    $CLI exec frr ip link set "$IFACE" master br-evpn
    $CLI exec frr bridge vlan add dev "$IFACE" vid ${MAC_VID} pvid untagged
    $CLI exec frr ip link set "$IFACE" up

    ############################################
    # 4. Add MAC-VRF VLAN/VNI mapping
    ############################################
    $CLI exec frr bridge vlan add dev br-evpn vid ${MAC_VID} self
    $CLI exec frr bridge vlan add dev vx-evpn vid ${MAC_VID}
    $CLI exec frr bridge vni add dev vx-evpn vni ${MAC_VNI}
    $CLI exec frr bridge vlan add dev vx-evpn vid ${MAC_VID} tunnel_info id ${MAC_VNI}

    ############################################
    # 5. Create Linux VRF for IP-VRF
    ############################################
    $CLI exec frr ip link add ${T} type vrf table $((100+i))
    $CLI exec frr ip link set ${T} up

    ############################################
    # 6. Add IP-VRF VLAN/VNI mapping
    ############################################
    $CLI exec frr bridge vlan add dev br-evpn vid ${IP_VID} self
    $CLI exec frr bridge vlan add dev vx-evpn vid ${IP_VID}
    $CLI exec frr bridge vni add dev vx-evpn vni ${IP_VNI}
    $CLI exec frr bridge vlan add dev vx-evpn vid ${IP_VID} tunnel_info id ${IP_VNI}

    ############################################
    # 7. Create SVI for IP-VRF, attach to VRF
    ############################################
    $CLI exec frr ip link add br-evpn.${IP_VID} link br-evpn type vlan id ${IP_VID}
    $CLI exec frr ip link set br-evpn.${IP_VID} addrgenmode none
    $CLI exec frr ip link set br-evpn.${IP_VID} master ${T}
    $CLI exec frr ip link set br-evpn.${IP_VID} up

  done

}

DUMMY=0
deploy_agnhost_container() {
    local name=$1
    local ip_addr=$2
    local net="${name}_net"
    
    # Calculate tenant-specific subnet/gateway from IP
    local subnet="${ip_addr%.*}.0/24"

    echo "Creating network $net ($subnet)..."
    
    # Clean up existing resources
    $CLI rm -f "$name" 2>/dev/null || true
    $CLI network rm -f "$net" 2>/dev/null || true

    # Create a standard bridge network
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

    # Verification: Fetch the IP using the specific Network name
    local actual_ip
    actual_ip=$($CLI inspect -f "{{.NetworkSettings.Networks.${net}.IPAddress}}" "$name")
    echo "Successfully deployed $name at $actual_ip"
}
############################################
# 6 EVPN Control Plane
############################################

create_vtep() {

oc apply -f - <<EOF
apiVersion: k8s.ovn.org/v1
kind: VTEP
metadata:
 name: evpn-vtep
spec:
 mode: Unmanaged
 cidrs:
 - 192.168.111.0/24
EOF

}

create_route_ads() {

oc apply -f - <<EOF
apiVersion: k8s.ovn.org/v1
kind: RouteAdvertisements
metadata:
  name: evpn-routes
spec:
  nodeSelector: {}
  frrConfigurationSelector: {}
  networkSelectors:
    - networkSelectionType: ClusterUserDefinedNetworks
      clusterUserDefinedNetworkSelector:
        networkSelector:
          matchLabels:
            evpn: "true"
  targetVRF: auto
  advertisements:
    - PodNetwork
EOF

}

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
# 7 Create Tenants
############################################
create_tenants() {

for ((i=0;i<NUM_TENANTS;i++))
do

TENANT=${TENANTS[$i]}
NS="l2vpn-${TENANT}"

MAC_VNI=$((BASE_VNI+i))
IP_VNI=$((BASE_IP_VNI+i))

cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ${NS}
  labels:
    network: ${TENANT}
    k8s.ovn.org/primary-user-defined-network: ${TENANT}-evpn
---
apiVersion: k8s.ovn.org/v1
kind: ClusterUserDefinedNetwork
metadata:
  name: ${TENANT}-evpn
  labels:
    evpn: "true"
spec:
  namespaceSelector:
    matchLabels:
      network: ${TENANT}
  network:
    topology: Layer2
    transport: EVPN
    layer2:
      role: Primary
      subnets:
      - "10.${i}.0.0/24"
    evpn:
      vtep: evpn-vtep
      macVRF:
        vni: ${MAC_VNI}
        routeTarget: "${FRR_ASN}:${MAC_VNI}"
      ipVRF:
        vni: ${IP_VNI}
        routeTarget: "${FRR_ASN}:${IP_VNI}"
EOF

done

}


############################################
# 8 Workloads
############################################

deploy_workloads() {

for ((i=0;i<NUM_TENANTS;i++))
do

local TENANT=${TENANTS[$i]}
local NS="l2vpn-${TENANT}"

kubectl -n ${NS} create deployment nettools \
--image docker.io/nicolaka/netshoot \
-- sleep infinity || true

kubectl -n ${NS} scale deploy nettools --replicas=2

done

}


############################################
# MAIN
############################################

deploy_frr_external_container

create_vtep
create_route_ads
create_frrconfig

create_tenants
deploy_workloads

echo "EVPN multi-tenant L2VPN setup completed"


