# EVPN Multi-Tenant Setup Scripts for OpenShift

Scripts to configure EVPN-based multi-tenant VPNs on an OpenShift (OCP) bare-metal
cluster using OVN-Kubernetes CUDNs, frr-k8s, and an external FRR container acting
as a BGP route reflector / VTEP peer.

## Scripts

| Script | Description |
|--------|-------------|
| `1_setup_EVPN_multi_tenants_L2.sh`                   | multi-tenants L2VPN only (MAC-VRF + IP-VRF) |
| `2_setup_EVPN_multi_tenants_L3.sh`                   | multi-tenant L3VPN only (IP-VRF) |
| `3_setup_EVPN_mixed_multi_tenants_L2_and_L3.sh`      | Mixed of 2 L2VPNs + 2 L3VPNs  |
| `1_cleanup_EVPN_multi_tenants_L2.sh`                 | Cleanup multi-tenants L2VPN only (preserves FeatureGate and CNO config) |
| `2_cleanup_EVPN_multi_tenants_L3.sh`                 | Cleanup multi-tenants L3VPN only (preserves FeatureGate and CNO config) |
| `3_cleanup_EVPN_mixed_multi_tenants_L2_and_L3.sh`    | Cleanup L2VPN and L3VPN setup (preserves FeatureGate and CNO config) |

## Prerequisites

- OpenShift 4.x bare-metal cluster with `TechPreviewNoUpgrade` FeatureGate support
- `oc` or `kubectl` configured with cluster-admin access
- `podman` (or `docker`) on the host where the external FRR container will run
- A Linux bridge on the host connected to the baremetal network (`192.168.111.0/24`)
  that cluster nodes are on
- FRRConfiguration YAML file(s) in the working directory (see below)

## FRRConfiguration Files

Each setup script expects one of the following files in the current working directory,
depending on the cluster's IP stack:

| Stack Type | Required File |
|------------|---------------|
| IPv4 single-stack | `receive-filtered-singlestackv4.yaml` |
| IPv6 single-stack | `receive-filtered-singlestackv6.yaml` |
| Dual-stack        | `receive-filtered-dualstack.yaml` |

These files contain the `FRRConfiguration` CRD that tells frr-k8s on each node
how to peer with the external FRR container and which routes to accept/filter.
The script auto-detects the stack type and applies the matching file.

## Baremetal Bridge Name

All scripts auto-detect the baremetal bridge at runtime by scanning for a Linux
bridge interface with an IP address in `192.168.111.0/24`. No manual configuration
is needed — the scripts will find the correct bridge automatically regardless of
its name (e.g., `sdn09bm`, `ostestbm`, `baremetal`, `br-ext`, etc.).

If no matching bridge is found, the script will print an error listing available
bridges on the system and exit.

## Usage

Run the setup scripts from the directory containing the FRRConfiguration YAML files:

```bash
# L2VPN only (default 3 tenants, or pass a number)
./1_setup_EVPN_multi_tenants_L2.sh [NUM_TENANTS]

# L3VPN only (default 3 tenants, or pass a number)
./2_setup_EVPN_multi_tenants_L3.sh [NUM_TENANTS]

# Mixed L2+L3 (fixed: 2 L2 + 2 L3 tenants)
./3_cleanup_EVPN_mixed_multi_tenants_L2_and_L3.sh
```

Cleanup 

```bash
./1_cleanup_EVPN_multi_tenants_L2.sh
./2_cleanup_EVPN_multi_tenants_L3.sh
./3_cleanup_EVPN_mixed_L2_L3.sh
```

## What Each Script Does

### Common Steps (all setup scripts)

1. **FeatureGate** — enables `TechPreviewNoUpgrade` (with MCP rollout wait)
2. **CNO Patch** — enables FRR routing capabilities, `routeAdvertisements`,
   Local Gateway mode with Global IP forwarding
3. **frr-k8s Upgrade** — sets `managementState: Unmanaged` and upgrades
   frr-k8s DaemonSet to FRR 10.4.2
4. **FRRConfiguration** — applies the stack-appropriate FRRConfiguration YAML
5. **VTEP** — creates an `Unmanaged` VTEP for `192.168.111.0/24`
6. **RouteAdvertisements** — advertises CUDN pod networks via EVPN
7. **External FRR** — deploys an FRR container on the baremetal bridge as a
   BGP route reflector peering with all cluster nodes via iBGP (AS 64512)
8. **Tenant CUDNs + Namespaces** — creates per-tenant ClusterUserDefinedNetworks
9. **Workloads** — deploys `nettools` pods in each tenant namespace

### L2VPN Specifics (`1_setup_EVPN_multi_tenants_L2.sh`)

- CUDN topology: **Layer2** with MAC-VRF + IP-VRF
- External FRR uses a **single EVPN bridge** (`br-evpn`) in **SVD mode**
  (Single VXLAN Device with `vnifilter`)
- Agnhost containers are placed **on the CUDN subnet** (e.g., `10.0.0.250`)
  and bridged to cluster pods via EVPN Type-2/Type-3 routes
- FRR interfaces to agnhost networks are attached as **bridge access ports**
  with per-tenant VLAN-to-VNI mappings

### L3VPN Specifics (`2_setup_EVPN_multi_tenants_L3.sh`)

- CUDN topology: **Layer3** with IP-VRF only
- External FRR uses **per-VRF bridges** with dedicated VXLAN devices
  for symmetric IRB (one `br-<tenant>` + `vxl-<VNI>` per tenant)
- Agnhost containers are on **separate routed subnets** (e.g., `172.20.0.100`)
  and reach cluster pods via EVPN Type-5 routes
- Agnhost default routes are pointed at the FRR container

### Mixed L2+L3 (`3_setup_EVPN_mixed_multi_tenants_L2_and_L3.sh`)

Combines both approaches on a single external FRR container:

| Tenant | VPN Type | Topology | CUDN Subnet | Agnhost IP | VNI(s) |
|--------|----------|----------|-------------|------------|--------|
| l2vpn-red | L2VPN | Layer2 | 10.0.0.0/24 | 10.0.0.250 | MAC=20100, IP=20200 |
| l2vpn-blue | L2VPN | Layer2 | 10.1.0.0/24 | 10.1.0.250 | MAC=20101, IP=20201 |
| l3vpn-orange | L3VPN | Layer3 | 10.10.0.0/16 | 172.20.0.100 | IP=30000 |
| l3vpn-green | L3VPN | Layer3 | 10.11.0.0/16 | 172.20.1.100 | IP=30001 |

Uses a **shared `br-evpn` bridge in SVD mode** for all tenants — L2 tenants get
MAC-VRF access ports, L3 tenants get IP-VRF SVIs on the same bridge.

## Testing Connectivity

After setup, verify BGP sessions and test pod-to-agnhost connectivity:

```bash
# Check BGP EVPN sessions on external FRR
podman exec frr vtysh -c "show bgp l2vpn evpn summary"

# Check EVPN VNI mappings
podman exec frr vtysh -c "show evpn vni"

# Check Type-5 routes (L3VPN)
podman exec frr vtysh -c "show bgp l2vpn evpn route type prefix"

# Check Type-2 routes (L2VPN)
podman exec frr vtysh -c "show bgp l2vpn evpn route type macip"

# Test L2VPN connectivity (bridged, same subnet)
oc -n l2vpn-red exec <pod> -- curl -s 10.0.0.250:8000/hostname

# Test L3VPN connectivity (routed, cross subnet)
oc -n l3vpn-orange exec <pod> -- curl -s 172.20.0.100:8000/hostname

# Check per-VRF routing on external FRR
podman exec frr vtysh -c "show ip route vrf red"
podman exec frr vtysh -c "show ip route vrf orange"
```

## Cleanup

cleanup script cleans up the setup that is created by its corresponding setup script, but keep the following preserved:

- FeatureGate (`TechPreviewNoUpgrade`)
- CNO config (FRR routing, routeAdvertisements, LGW, Global forwarding)
- frr-k8s 10.4.2 image

This allows re-running a setup script without waiting for FeatureGate/CNO rollouts.

## Network Architecture

```
   Cluster Nodes (192.168.111.20-25)           External FRR (192.168.111.3)
  ┌─────────────────────────────────┐         ┌──────────────────────────────┐
  │  frr-k8s (per-node)             │  iBGP   │  FRR 10.4.2                  │
  │  ┌───────────────────────┐      │◄───────►│  BGP Route Reflector         │
  │  │ OVN-K EVPN Controller │      │  AS     │                              │
  │  │ (generates FRR config │      │  64512  │  VRFs: red, blue,            │
  │  │  from CUDNs + RAs)    │      │         │        orange, green         │
  │  └───────────────────────┘      │         │                              │
  │                                 │  VXLAN  │  br-evpn (SVD bridge)        │
  │  CUDN pods ◄────────────────────┼─────────┼──► agnhost containers        │
  │  (10.x.0.0/24 or 10.x.0.0/16)   │  tunnel │  (L2: 10.x.0.250             │
  │                                 │         │   L3: 172.20.x.100)          │
  └─────────────────────────────────┘         └──────────────────────────────┘
              baremetal bridge (192.168.111.0/24)
```
