#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

# --- Configuration & Variables ---
FRR_K8S_VERSION=v0.0.21
FRR_TMP_DIR=$(mktemp -d -u)
AGNHOST_SUBNET_V4=172.20.0.0/16
AGNHOST_SUBNET_V6=2001:db8:2::/64

# Cluster Network Defaults
CLUSTER_NETWORK_V4="10.128.0.0/14"
CLUSTER_NETWORK_V6="fd01::/48"

# --- 1. TechPreview Check & Enable ---
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

# --- 2. CNO Configuration Check & Enable ---
echo "Checking CNO configuration..."
CNO_CONFIG=$(oc get network.operator cluster -o json)
HAS_FRR=$(echo "$CNO_CONFIG" | jq -r '.spec.additionalRoutingCapabilities.providers // [] | contains(["FRR"])')
HAS_RA=$(echo "$CNO_CONFIG" | jq -r '.spec.defaultNetwork.ovnKubernetesConfig.routeAdvertisements // "" | . == "Enabled"')
HAS_LGW=$(echo "$CNO_CONFIG" | jq -r '.spec.defaultNetwork.ovnKubernetesConfig.gatewayConfig.routingViaHost // false')

if [ "$HAS_FRR" == "true" ] && [ "$HAS_RA" == "true" ] && [ "$HAS_LGW" == "true" ]; then
    echo "CNO (FRR, RouteAds, LGW) already configured. Skipping patch."
else
    echo "Patching CNO for EVPN requirements..."
    oc patch Network.operator.openshift.io cluster --type=merge -p='
    {
      "spec": {
        "additionalRoutingCapabilities": { "providers": ["FRR"] },
        "defaultNetwork": {
          "ovnKubernetesConfig": {
            "routeAdvertisements": "Enabled",
            "gatewayConfig": {
              "ipForwarding": "Global",
              "routingViaHost": true
            }
          }
        }
      }
    }'
    
    # Critical: Give the operator 30-60 seconds to "notice" the change and start Progressing
    echo "Waiting 60s for Network Operator to acknowledge patch..."
    sleep 60
    
    echo "Waiting for Network Operator to reach stable state (True False False)..."
    # This loop checks that Available=True AND Progressing=False AND Degraded=False
    while true; do
        # Fetch conditions in a stable order: Available Progressing Degraded
        STATUS=$(oc get co network -o jsonpath='{range .status.conditions[?(@.type=="Available")]}{.status}{" "}{end}{range .status.conditions[?(@.type=="Progressing")]}{.status}{" "}{end}{range .status.conditions[?(@.type=="Degraded")]}{.status}{end}')
        
        echo "Current Status (Avail/Prog/Deg): $STATUS"
        
        if [ "$STATUS" == "True False False" ]; then
            # Verify one last time to avoid "flapping" status
            sleep 5
            STATUS=$(oc get co network -o jsonpath='{range .status.conditions[?(@.type=="Available")]}{.status}{" "}{end}{range .status.conditions[?(@.type=="Progressing")]}{.status}{" "}{end}{range .status.conditions[?(@.type=="Degraded")]}{.status}{end}')
            if [ "$STATUS" == "True False False" ]; then
                break
            fi
        fi
        sleep 15
    done
    echo "CNO is stable."
fi

# --- IP Stack Detection ---
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

# --- Helper Functions ---

clone_frr() {
  if [ ! -d "$FRR_TMP_DIR" ]; then
    mkdir -p "$FRR_TMP_DIR" && trap 'rm -rf $FRR_TMP_DIR' EXIT
    pushd "$FRR_TMP_DIR" > /dev/null
    git clone --depth 1 --branch $FRR_K8S_VERSION https://github.com/metallb/frr-k8s
    popd > /dev/null
  fi
}

generate_frr_config() {
    local NODE_IPS="$1"
    local OUTPUT_FILE="$2"
    read -ra ips <<< "$NODE_IPS"
    local ipv4_list=()
    local ipv6_list=()
    for ip in "${ips[@]}"; do
        [[ $ip =~ ^[0-9]+\. ]] && ipv4_list+=("$ip") || ipv6_list+=("$ip")
    done

    cat > "$OUTPUT_FILE" << EOF
router bgp 64512
 no bgp default ipv4-unicast
 no bgp network import-check
EOF
    for ip in "${ipv4_list[@]}" "${ipv6_list[@]}"; do echo " neighbor $ip remote-as 64512" >> "$OUTPUT_FILE"; done

    echo -e "\n address-family ipv4 unicast\n  network ${AGNHOST_SUBNET_V4}\n exit-address-family" >> "$OUTPUT_FILE"
    echo -e "\n address-family ipv6 unicast\n  network ${AGNHOST_SUBNET_V6}\n exit-address-family" >> "$OUTPUT_FILE"

    echo -e "\n address-family l2vpn evpn\n  advertise-all-vni" >> "$OUTPUT_FILE"
    for ip in "${ipv4_list[@]}" "${ipv6_list[@]}"; do
        echo "  neighbor $ip activate" >> "$OUTPUT_FILE"
        echo "  neighbor $ip route-reflector-client" >> "$OUTPUT_FILE"
	echo "  neighbor $ip send-community extended" >> "$OUTPUT_FILE"
    done
    echo " exit-address-family" >> "$OUTPUT_FILE"
}

deploy_agnhost_container() {
  echo "Deploying agnhost..."
  local ARGS=("-d" "--privileged" "--name" "agnhost" "--network" "agnhost_net" "--rm")
  [[ "$IS_V4" == true ]] && ARGS+=("--ip" "172.20.0.100")
  [[ "$IS_V6" == true ]] && ARGS+=("--ip6" "2001:db8:2::100")

  podman run "${ARGS[@]}" registry.k8s.io/e2e-test-images/agnhost:2.40 netexec --http-port=8000
  [[ "$IS_V4" == true ]] && podman exec agnhost ip route add default dev eth0 via 172.20.0.2 || true
  [[ "$IS_V6" == true ]] && podman exec agnhost ip -6 route add default dev eth0 via 2001:db8:2::2 || true
}

deploy_frr_external_container() {
  echo "Deploying external FRR container..."
  clone_frr
  NODES=$(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}')
  FRR_CONF_DIR=$(mktemp -d -t frr-XXXX)
  generate_frr_config "$NODES" "$FRR_CONF_DIR/frr.conf"
  cp "${FRR_TMP_DIR}"/frr-k8s/hack/demo/frr/daemons "$FRR_CONF_DIR"
  chmod a+rw "$FRR_CONF_DIR"/*

  podman run -d --privileged --network agnhost_net --ip 172.20.0.2 --rm --name frr --volume "$FRR_CONF_DIR":/etc/frr quay.io/frrouting/frr:10.4.1
  podman network connect sdn09bm_net frr

  if [ "$IS_V4" = true ]; then
    podman exec frr ip addr add dev eth1 192.168.111.3/24
    podman exec frr ip route add default dev eth1 via 192.168.111.1 || true
  fi
  if [ "$IS_V6" = true ]; then
    podman exec frr ip -6 addr add dev eth1 fd2e:6f44:5dd8:c956::3/64
    podman exec frr ip -6 route add default dev eth1 via fd2e:6f44:5dd8:c956::1 || true
  fi
}

# --- 3. external setup ---
podman rm -f frr agnhost || true
podman network rm sdn09bm_net agnhost_net || true
podman network create --driver bridge --ipam-driver=none --opt com.docker.network.bridge.name=sdn09bm sdn09bm_net
ip link add dummy0 type dummy 2>/dev/null || true
ip link set dummy0 up
podman network create --driver macvlan -o parent=dummy0 --ipv6 --subnet=${AGNHOST_SUBNET_V4} --subnet=${AGNHOST_SUBNET_V6} agnhost_net

deploy_agnhost_container
deploy_frr_external_container

# --- 4. update FRR-K8S ---
echo "Waiting for openshift-frr-k8s namespace..."
until kubectl get namespace openshift-frr-k8s &>/dev/null; do sleep 5; done
oc patch Network.operator.openshift.io cluster --type='merge' -p='{"spec":{"managementState":"Unmanaged"}}'
oc set image daemonset/frr-k8s -n openshift-frr-k8s frr=quay.io/frrouting/frr:10.4.1 reloader=quay.io/frrouting/frr:10.4.1
oc rollout status daemonset/frr-k8s -n openshift-frr-k8s --timeout=5m

# --- 5. Apply EVPN Configuration (VTEP, RA, Peering) ---

echo "Applying VTEP configuration..."
# Define the VTEP CIDRs based on the detected stack
VTEP_CIDRS=""
[[ "$IS_V4" == true ]] && VTEP_CIDRS+="    - 192.168.111.0/24"
[[ "$IS_V6" == true ]] && VTEP_CIDRS+=$'\n'"    - fd2e:6f44:5dd8:c956::/64"

oc apply -f - <<EOF
apiVersion: k8s.ovn.org/v1
kind: VTEP
metadata:
  name: evpn-vtep
spec:
  mode: Unmanaged
  cidrs:
${VTEP_CIDRS}
EOF

echo "Applying RouteAdvertisements..."
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
  advertisements: [PodNetwork]
EOF

# Apply Stack-specific Peering
CASE_FILE="./receive-filtered-singlestackv4.yaml"
[[ "$STACK_TYPE" == "ipv6single" ]] && CASE_FILE="./receive-filtered-singlestackv6.yaml"
[[ "$STACK_TYPE" == "dualstack" ]] && CASE_FILE="./receive-filtered-dualstack.yaml"
[ -f "$CASE_FILE" ] && oc apply -f "$CASE_FILE"

# Create EVPN L2 Network & Workload
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: evpn-demo
  labels:
    network: evpn-demo
    k8s.ovn.org/primary-user-defined-network: evpn-l2
---
apiVersion: k8s.ovn.org/v1
kind: ClusterUserDefinedNetwork
metadata:
  name: evpn-l2
  labels: { evpn: "true" }
spec:
  namespaceSelector: { matchLabels: { network: evpn-demo } }
  network:
    topology: Layer2
    transport: EVPN
    layer2: { role: Primary, subnets: ["10.200.0.0/16"] }
    evpn:
      vtep: evpn-vtep
      macVRF: { vni: 20100, routeTarget: "65000:20100" }
      ipVRF: { vni: 20101, routeTarget: "65000:20101" }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nettools
  namespace: evpn-demo
spec:
  replicas: 2
  selector: { matchLabels: { app: nettools } }
  template:
    metadata: { labels: { app: nettools } }
    spec:
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector: { matchLabels: { app: nettools } }
            topologyKey: kubernetes.io/hostname
      containers:
      - name: nettools
        image: docker.io/nicolaka/netshoot:v0.13
        command: ["sleep", "infinity"]
EOF

# --- 6. Hypervisor Routing & Rules ---
if [ "$IS_V4" = true ]; then
    ip route add $CLUSTER_NETWORK_V4 via 192.168.111.3 dev sdn09bm || true
    iptables -t filter -I FORWARD -s ${CLUSTER_NETWORK_V4} -i sdn09bm -j ACCEPT
    iptables -t filter -I FORWARD -d ${CLUSTER_NETWORK_V4} -o sdn09bm -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    iptables -t nat -I POSTROUTING -s ${CLUSTER_NETWORK_V4} ! -d 192.168.111.1/24 -j MASQUERADE
fi
if [ "$IS_V6" = true ]; then
    ip -6 route add $CLUSTER_NETWORK_V6 via fd2e:6f44:5dd8:c956::3 dev sdn09bm || true
    ip6tables -t filter -I FORWARD -s ${CLUSTER_NETWORK_V6} -i sdn09bm -j ACCEPT
    ip6tables -t filter -I FORWARD -d ${CLUSTER_NETWORK_V6} -o sdn09bm -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    ip6tables -t nat -I POSTROUTING -s ${CLUSTER_NETWORK_V6} ! -d fd2e:6f44:5dd8:c956::/64 -j MASQUERADE
fi

echo "EVPN Setup Complete."

