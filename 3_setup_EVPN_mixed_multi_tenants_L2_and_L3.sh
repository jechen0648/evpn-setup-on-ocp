#!/usr/bin/env bash
set -euo pipefail

CLI=$(command -v podman || command -v docker)
KCLI=$(command -v kubectl || command -v oc)

############################################
# CONFIG
############################################

FRR_VERSION="10.4.2"
FRR_IMAGE="quay.io/frrouting/frr:${FRR_VERSION}"
FRR_ASN=64512

FRR_CONTAINER_IP="192.168.111.3"
FRR_CONTAINER_GW="192.168.111.1"

# L2VPN tenants (MAC-VRF + IP-VRF, Layer2 topology)
L2_TENANTS=(red blue)
L2_BASE_MAC_VNI=20100
L2_BASE_IP_VNI=20200

# L3VPN tenants (IP-VRF only, Layer3 topology)
L3_TENANTS=(orange green)
L3_BASE_VNI=30000

# L3 agnhost subnets (separate from CUDN, routed via Type-5)
L3_AGN_BASE="172.20"

############################################
# Helpers
############################################

node_ips() {
  $KCLI get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}'
}

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

connect_frr_to_network() {
    local net=$1
    echo "Connecting FRR to ${net}..."

    local BEFORE_IFS
    BEFORE_IFS=$($CLI exec frr ip -o link show | awk -F': ' '{print $2}')

    if [ -n "${2:-}" ]; then
        $CLI network connect --ip "$2" "$net" frr
    else
        $CLI network connect "$net" frr
    fi

    sleep 1

    local AFTER_IFS
    AFTER_IFS=$($CLI exec frr ip -o link show | awk -F': ' '{print $2}')

    DETECTED_IFACE=$(comm -13 <(echo "$BEFORE_IFS" | sort) <(echo "$AFTER_IFS" | sort) | head -n1)
    DETECTED_IFACE="${DETECTED_IFACE%%@*}"

    if [ -z "$DETECTED_IFACE" ]; then
        echo "ERROR: could not detect new interface on FRR for network $net"
        exit 1
    fi
    echo "Found FRR interface $DETECTED_IFACE"
}

############################################
# 1. FeatureGate
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
# 2. Patch CNO for EVPN
############################################

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
# 3. Upgrade frr-k8s to 10.4.2
############################################

echo "Upgrading frr-k8s to ${FRR_VERSION}..."
$KCLI patch Network.operator.openshift.io cluster --type merge -p '{"spec":{"managementState":"Unmanaged"}}'

$KCLI set image daemonset/frr-k8s -n openshift-frr-k8s \
    frr=${FRR_IMAGE} \
    reloader=${FRR_IMAGE}

$KCLI rollout status daemonset/frr-k8s -n openshift-frr-k8s --timeout=10m

############################################
# 4. FRRConfiguration
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
# 5. Generate External FRR Config
############################################

generate_frr_config() {
cat <<EOF
log stdout debugging
frr defaults traditional
EOF

# VRF-VNI sections for L2 IP-VRFs
for ((i=0;i<${#L2_TENANTS[@]};i++)); do
    T=${L2_TENANTS[$i]}
    IP_VNI=$((L2_BASE_IP_VNI+i))
    echo "vrf ${T}"
    echo " vni ${IP_VNI}"
    echo "exit-vrf"
    echo "!"
done

# VRF-VNI sections for L3 IP-VRFs
for ((i=0;i<${#L3_TENANTS[@]};i++)); do
    T=${L3_TENANTS[$i]}
    VNI=$((L3_BASE_VNI+i))
    echo "vrf ${T}"
    echo " vni ${VNI}"
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

# L2 MAC-VRF VNI route-targets in global section
for ((i=0;i<${#L2_TENANTS[@]};i++)); do
    MAC_VNI=$((L2_BASE_MAC_VNI+i))
    RT="${FRR_ASN}:${MAC_VNI}"
cat <<EOF
  vni ${MAC_VNI}
   rd ${RT}
   route-target import ${RT}
   route-target export ${RT}
  exit-vni
EOF
done

echo " exit-address-family"
echo "exit"
echo "!"

# Per-VRF BGP for L2 IP-VRFs
for ((i=0;i<${#L2_TENANTS[@]};i++)); do
    T=${L2_TENANTS[$i]}
    IP_VNI=$((L2_BASE_IP_VNI+i))
    RT="${FRR_ASN}:${IP_VNI}"
cat <<EOT
router bgp ${FRR_ASN} vrf ${T}
 address-family l2vpn evpn
  rd ${RT}
  route-target import ${RT}
  route-target export ${RT}
  advertise ipv4 unicast
 exit-address-family
EOT
done

# Per-VRF BGP for L3 IP-VRFs
for ((i=0;i<${#L3_TENANTS[@]};i++)); do
    T=${L3_TENANTS[$i]}
    VNI=$((L3_BASE_VNI+i))
    RT="${FRR_ASN}:${VNI}"
    AGN_SUBNET="${L3_AGN_BASE}.${i}.0/24"
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
done
}

############################################
# 6. Deploy External FRR + Agnhosts
############################################

deploy_external_frr() {
  echo "Deploying External FRR Container..."
  local frr_dir
  frr_dir=$(mktemp -d)

  generate_frr_config > ${frr_dir}/frr.conf
  touch ${frr_dir}/vtysh.conf
  cat <<DEOF > ${frr_dir}/daemons
bgpd=yes
zebra=yes
DEOF
  chmod a+rw ${frr_dir}/*

  # Detect baremetal bridge
  BRIDGE=""
  for br in $(ip link show type bridge 2>/dev/null | awk -F': ' '/^[0-9]/{print $2}'); do
      if ip -4 addr show "$br" 2>/dev/null | grep -q "192\.168\.111\."; then
          BRIDGE="$br"
          break
      fi
  done
  if [ -z "$BRIDGE" ]; then
      echo "ERROR: No bridge found carrying 192.168.111.0/24."
      ip link show type bridge 2>/dev/null | awk -F': ' '/^[0-9]/{print "  " $2}'
      exit 1
  fi
  echo "Found baremetal bridge: $BRIDGE"

  # Start FRR container
  $CLI rm -f frr 2>/dev/null || true
  $CLI network rm -f ${BRIDGE}_net 2>/dev/null || true

  $CLI network create \
      --driver bridge \
      --ipam-driver=none \
      --opt com.docker.network.bridge.name=${BRIDGE} \
      ${BRIDGE}_net

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
  # Create shared EVPN bridge + VXLAN (SVD)
  # Used by L2 tenants (MAC-VRF access ports)
  # and L3 tenants (IP-VRF SVIs)
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
  # L2 Tenants: agnhost on CUDN subnet,
  #   bridged via MAC-VRF access port
  ############################################
  local vid_counter=100

  for ((i=0;i<${#L2_TENANTS[@]};i++)); do
    T=${L2_TENANTS[$i]}
    MAC_VNI=$((L2_BASE_MAC_VNI+i))
    IP_VNI=$((L2_BASE_IP_VNI+i))
    MAC_VID=$((vid_counter))
    IP_VID=$((vid_counter+1))
    vid_counter=$((vid_counter+2))

    AGNHOST_IP="10.${i}.0.250"

    echo "=== L2 Tenant ${T}: MAC-VRF VNI=${MAC_VNI} VID=${MAC_VID}, IP-VRF VNI=${IP_VNI} VID=${IP_VID} ==="

    # Deploy agnhost on CUDN subnet
    deploy_agnhost_container "agnhost_${T}" "${AGNHOST_IP}"

    # Connect FRR and detect interface
    connect_frr_to_network "agnhost_${T}_net"

    # Move FRR interface to bridge as MAC-VRF access port
    $CLI exec frr ip link set "$DETECTED_IFACE" master br-evpn
    $CLI exec frr bridge vlan add dev "$DETECTED_IFACE" vid ${MAC_VID} pvid untagged
    $CLI exec frr ip link set "$DETECTED_IFACE" up

    # MAC-VRF VLAN/VNI mapping
    $CLI exec frr bridge vlan add dev br-evpn vid ${MAC_VID} self
    $CLI exec frr bridge vlan add dev vx-evpn vid ${MAC_VID}
    $CLI exec frr bridge vni add dev vx-evpn vni ${MAC_VNI}
    $CLI exec frr bridge vlan add dev vx-evpn vid ${MAC_VID} tunnel_info id ${MAC_VNI}

    # Linux VRF for IP-VRF
    $CLI exec frr ip link add ${T} type vrf table $((100+i))
    $CLI exec frr ip link set ${T} up

    # IP-VRF VLAN/VNI mapping + SVI
    $CLI exec frr bridge vlan add dev br-evpn vid ${IP_VID} self
    $CLI exec frr bridge vlan add dev vx-evpn vid ${IP_VID}
    $CLI exec frr bridge vni add dev vx-evpn vni ${IP_VNI}
    $CLI exec frr bridge vlan add dev vx-evpn vid ${IP_VID} tunnel_info id ${IP_VNI}

    $CLI exec frr ip link add br-evpn.${IP_VID} link br-evpn type vlan id ${IP_VID}
    $CLI exec frr ip link set br-evpn.${IP_VID} addrgenmode none
    $CLI exec frr ip link set br-evpn.${IP_VID} master ${T}
    $CLI exec frr ip link set br-evpn.${IP_VID} up
  done

  ############################################
  # L3 Tenants: agnhost on separate subnet,
  #   routed via IP-VRF + per-VRF bridge
  ############################################
  for ((i=0;i<${#L3_TENANTS[@]};i++)); do
    T=${L3_TENANTS[$i]}
    VNI=$((L3_BASE_VNI+i))
    TABLE=$((200+i))
    IP_VID=$((vid_counter))
    vid_counter=$((vid_counter+1))

    AGN_GW_IP="${L3_AGN_BASE}.${i}.1"
    AGN_HOST_IP="${L3_AGN_BASE}.${i}.100"

    echo "=== L3 Tenant ${T}: IP-VRF VNI=${VNI} VID=${IP_VID} ==="

    # Create Linux VRF
    $CLI exec frr ip link add ${T} type vrf table ${TABLE}
    $CLI exec frr ip link set ${T} up

    # Deploy agnhost on separate routed subnet
    deploy_agnhost_container "agnhost_${T}" "${AGN_HOST_IP}"

    # Connect FRR with specific gateway IP
    connect_frr_to_network "agnhost_${T}_net" "${AGN_GW_IP}"

    # Attach FRR interface to VRF
    $CLI exec frr ip link set dev "$DETECTED_IFACE" master ${T}
    $CLI exec frr ip link set dev "$DETECTED_IFACE" up

    # IP-VRF VLAN/VNI mapping on shared bridge
    $CLI exec frr bridge vlan add dev br-evpn vid ${IP_VID} self
    $CLI exec frr bridge vlan add dev vx-evpn vid ${IP_VID}
    $CLI exec frr bridge vni add dev vx-evpn vni ${VNI}
    $CLI exec frr bridge vlan add dev vx-evpn vid ${IP_VID} tunnel_info id ${VNI}

    # SVI on shared bridge, attached to VRF
    $CLI exec frr ip link add br-evpn.${IP_VID} link br-evpn type vlan id ${IP_VID}
    $CLI exec frr ip link set br-evpn.${IP_VID} addrgenmode none
    $CLI exec frr ip link set br-evpn.${IP_VID} master ${T}
    $CLI exec frr ip link set br-evpn.${IP_VID} up

    # Set agnhost default route via FRR
    echo "Setting agnhost_${T} default route via FRR (${AGN_GW_IP})..."
    $CLI exec "agnhost_${T}" ip route replace default via "${AGN_GW_IP}" dev eth0
  done
}

############################################
# 7. EVPN Control Plane
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
  name: evpn-ads
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
# 8. Create Tenants (L2 + L3 CUDNs)
############################################

create_tenants() {

  # L2 tenants: Layer2 topology with MAC-VRF + IP-VRF
  for ((i=0;i<${#L2_TENANTS[@]};i++)); do
    T=${L2_TENANTS[$i]}
    NS="l2vpn-${T}"
    MAC_VNI=$((L2_BASE_MAC_VNI+i))
    IP_VNI=$((L2_BASE_IP_VNI+i))

    echo "Creating L2 tenant: ${NS}..."
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

  # L3 tenants: Layer3 topology with IP-VRF only
  for ((i=0;i<${#L3_TENANTS[@]};i++)); do
    T=${L3_TENANTS[$i]}
    NS="l3vpn-${T}"
    VNI=$((L3_BASE_VNI+i))
    SUBNET_SECOND=$((i+10))

    echo "Creating L3 tenant: ${NS}..."
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
        - cidr: "10.${SUBNET_SECOND}.0.0/16"
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
# 9. Deploy Workloads
############################################

deploy_workloads() {
  for ((i=0;i<${#L2_TENANTS[@]};i++)); do
    local T=${L2_TENANTS[$i]}
    local NS="l2vpn-${T}"
    echo "Deploying workload in ${NS}..."
    $KCLI -n ${NS} create deployment nettools \
        --image docker.io/nicolaka/netshoot \
        -- sleep infinity || true
    $KCLI -n ${NS} scale deploy nettools --replicas=2
    $KCLI -n ${NS} rollout status deployment/nettools --timeout=2m
  done

  for ((i=0;i<${#L3_TENANTS[@]};i++)); do
    local T=${L3_TENANTS[$i]}
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
create_tenants
deploy_workloads

echo ""
echo "============================================"
echo "Mixed L2+L3 EVPN Setup Complete"
echo "============================================"
echo ""
echo "L2VPN tenants (MAC-VRF + IP-VRF, Layer2):"
echo "  l2vpn-red   : CUDN 10.0.0.0/24, agnhost_red   at 10.0.0.250"
echo "  l2vpn-blue  : CUDN 10.1.0.0/24, agnhost_blue  at 10.1.0.250"
echo ""
echo "L3VPN tenants (IP-VRF only, Layer3):"
echo "  l3vpn-orange: CUDN 10.10.0.0/16, agnhost_orange at 172.20.0.100"
echo "  l3vpn-green : CUDN 10.11.0.0/16, agnhost_green  at 172.20.1.100"
echo ""
echo "Test L2 connectivity (same subnet, bridged):"
echo "  oc -n l2vpn-red exec <pod> -- curl -s 10.0.0.250:8000/hostname"
echo ""
echo "Test L3 connectivity (cross subnet, routed):"
echo "  oc -n l3vpn-orange exec <pod> -- curl -s 172.20.0.100:8000/hostname"
