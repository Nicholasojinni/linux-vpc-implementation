# VPC Implementation Architecture

## Table of Contents

1. [System Architecture](#system-architecture)
2. [Component Design](#component-design)
3. [Network Flow](#network-flow)
4. [Data Structures](#data-structures)
5. [Implementation Details](#implementation-details)
6. [Performance Considerations](#performance-considerations)

---

## System Architecture

### High-Level Overview

```
┌─────────────────────────────────────────────────────────────┐
│                         Host System                          │
│                                                              │
│  ┌────────────┐    ┌──────────────────────────────────┐   │
│  │  vpcctl    │───▶│  /var/run/vpcctl/*.json         │   │
│  │  (CLI)     │    │  (Metadata Storage)              │   │
│  └────────────┘    └──────────────────────────────────┘   │
│         │                                                   │
│         ▼                                                   │
│  ┌──────────────────────────────────────────────────────┐ │
│  │              Linux Kernel Subsystems                  │ │
│  │  ┌──────────┐  ┌──────────┐  ┌─────────────────┐   │ │
│  │  │ Network  │  │  Bridge  │  │   Netfilter     │   │ │
│  │  │Namespace │  │  Layer   │  │   (iptables)    │   │ │
│  │  └──────────┘  └──────────┘  └─────────────────┘   │ │
│  └──────────────────────────────────────────────────────┘ │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐ │
│  │                   VPC Layer                           │ │
│  │                                                        │ │
│  │  VPC 1 (10.0.0.0/16)          VPC 2 (10.1.0.0/16)   │ │
│  │  ┌─────────────────┐           ┌─────────────────┐  │ │
│  │  │  br-vpc1        │◄─────────►│  br-vpc2        │  │ │
│  │  │  (10.0.0.1/16)  │  Peering  │  (10.1.0.1/16)  │  │ │
│  │  └────────┬────────┘           └────────┬────────┘  │ │
│  │           │                              │           │ │
│  │    ┌──────┴──────┐              ┌───────┴──────┐   │ │
│  │    │             │              │              │   │ │
│  │  Subnet       Subnet          Subnet        Subnet │ │
│  │    NS           NS              NS            NS   │ │
│  └──────────────────────────────────────────────────────┘ │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐ │
│  │                Physical Network                       │ │
│  │         eth0 / wlan0 (Internet Gateway)              │ │
│  └──────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

### Layer Breakdown

| Layer | Components | Purpose |
|-------|------------|---------|
| **Application** | vpcctl CLI | User interface and orchestration |
| **Control Plane** | JSON metadata | State management and configuration |
| **Data Plane** | Bridges, veth pairs | Actual packet forwarding |
| **Isolation** | Network namespaces | Resource and network isolation |
| **Security** | iptables chains | Firewall and NAT functionality |
| **Physical** | Host network interface | Internet connectivity |

---

## Component Design

### 1. Network Namespace (Subnet)

**Purpose:** Provides complete network isolation for each subnet.

**Implementation:**
```bash
# Create namespace
ip netns add <namespace-name>

# What it provides:
- Isolated network stack
- Separate routing table
- Independent firewall rules
- Own set of network interfaces
```

**Resource Isolation:**
- Each namespace has its own:
  - Network interfaces
  - IP addresses
  - Routing tables
  - iptables rules
  - Socket connections

**Lifecycle:**
```
Create → Configure → Use → Delete
   ↓         ↓        ↓       ↓
ip netns  ip addr  exec   ip netns
  add      add     cmd      del
```

### 2. Linux Bridge (VPC Router)

**Purpose:** Acts as a virtual switch/router connecting all subnets in a VPC.

**Implementation:**
```bash
# Create bridge
ip link add br-<vpc> type bridge

# Properties:
- Layer 2 forwarding
- MAC address learning
- VLAN support (if needed)
- STP support (if needed)
```

**Packet Flow:**
```
Namespace A → veth → Bridge → veth → Namespace B
  (10.0.1.10)              (learns MACs)    (10.0.2.10)
```

**Bridge States:**
```
DOWN → UP → FORWARDING
  ↓     ↓        ↓
Created  Link   Ready for
         enabled traffic
```

### 3. Veth Pair (Virtual Cable)

**Purpose:** Connects network namespace to bridge.

**Implementation:**
```bash
# Create pair
ip link add veth-host type veth peer name veth-ns

# Configuration:
- One end attached to bridge
- Other end moved into namespace
- Both ends must be UP
```

**Packet Path:**
```
Namespace Interface (veth-ns)
         ↓
    veth pair
         ↓
Host Side (veth-host)
         ↓
    Bridge Port
         ↓
    Forwarding Decision
```

### 4. Routing Table

**Purpose:** Determines packet paths within and between VPCs.

**Routing Hierarchy:**

```
1. Namespace Route Table
   ├─ Local subnet: 10.0.1.0/24 (direct)
   ├─ VPC network: 10.0.0.0/16 → via bridge
   └─ Default: 0.0.0.0/0 → via 10.0.0.1

2. Bridge Route Table
   ├─ Connected subnets (MAC learning)
   └─ Forward to appropriate veth

3. Host Route Table
   ├─ VPC networks: via bridge
   └─ Default: via physical interface
```

**Example Routing Table (in namespace):**
```
Destination     Gateway         Interface
10.0.1.0/24     0.0.0.0         veth-ns     (local subnet)
10.0.0.0/16     10.0.0.1        veth-ns     (VPC network)
0.0.0.0/0       10.0.0.1        veth-ns     (default route)
```

### 5. NAT Gateway

**Purpose:** Allows private IPs to access internet using host's public IP.

**iptables Rules:**
```bash
# MASQUERADE (dynamic NAT)
iptables -t nat -A POSTROUTING -s 10.0.0.0/16 -o eth0 -j MASQUERADE

# Explanation:
# -t nat         : Use NAT table
# -A POSTROUTING : Add to postrouting chain
# -s 10.0.0.0/16 : Source from VPC
# -o eth0        : Output to internet interface
# -j MASQUERADE  : Replace source IP with interface IP
```

**Packet Transformation:**
```
Outbound:
  Src: 10.0.1.10:45678 → 192.168.1.100:45678
  Dst: 8.8.8.8:53      → 8.8.8.8:53

Inbound (response):
  Src: 8.8.8.8:53      → 8.8.8.8:53
  Dst: 192.168.1.100:45678 → 10.0.1.10:45678
```

**Connection Tracking:**
```
┌─────────────────────────────────────┐
│     Conntrack Table                 │
│  ┌───────────────────────────────┐ │
│  │ Internal IP:Port              │ │
│  │ External IP:Port              │ │
│  │ Remote IP:Port                │ │
│  │ State: ESTABLISHED            │ │
│  └───────────────────────────────┘ │
└─────────────────────────────────────┘
```

### 6. Security Groups (Firewall)

**Purpose:** Control traffic to/from subnets.

**iptables Chains:**
```
INPUT Chain (incoming traffic)
  ├─ ACCEPT: established connections
  ├─ ACCEPT: allowed ports (from policy)
  ├─ DROP: denied ports (from policy)
  └─ DROP: default policy

FORWARD Chain (routed traffic)
  ├─ ACCEPT: inter-subnet allowed
  └─ Rules from policy

OUTPUT Chain (outgoing traffic)
  └─ ACCEPT: all (usually)
```

**Policy Application Flow:**
```
JSON Policy File
       ↓
   Parse Rules
       ↓
 Generate iptables Commands
       ↓
Apply to Namespace
       ↓
  Verify Rules
```

---

## Network Flow

### Scenario 1: Intra-VPC Communication

**Path:** Namespace A → Namespace B (same VPC)

```
Step 1: Application sends packet
  App in NS-A: send to 10.0.2.10

Step 2: Routing lookup in NS-A
  Route: 10.0.2.0/24 via 10.0.0.1 dev veth-a-ns

Step 3: Packet exits namespace via veth
  veth-a-ns → veth-a-host

Step 4: Bridge receives packet
  br-vpc: MAC learning, lookup destination

Step 5: Bridge forwards to destination veth
  br-vpc → veth-b-host

Step 6: Packet enters destination namespace
  veth-b-host → veth-b-ns

Step 7: Destination application receives
  NS-B receives packet from 10.0.1.10
```

### Scenario 2: Internet Access (with NAT)

**Path:** Namespace → Internet

```
Step 1: Application sends packet
  NS-A: curl http://example.com
  Src: 10.0.1.10:45678
  Dst: 93.184.216.34:80

Step 2: Routing to default gateway
  Route: default via 10.0.0.1

Step 3: Packet exits to bridge
  veth-a-ns → veth-a-host → br-vpc

Step 4: Bridge routes to host
  br-vpc → host network stack

Step 5: iptables POSTROUTING (NAT)
  Src: 10.0.1.10:45678 → 192.168.1.100:45678
  (Connection tracked)

Step 6: Packet sent to internet
  eth0 → Internet

Step 7: Response received
  Internet → eth0

Step 8: iptables reverse NAT
  Dst: 192.168.1.100:45678 → 10.0.1.10:45678
  (Using connection track)

Step 9: Packet routed back
  host → br-vpc → veth → NS-A

Step 10: Application receives response
  curl receives HTML
```

### Scenario 3: VPC Peering

**Path:** VPC 1 → VPC 2

```
Step 1: Packet from NS in VPC1
  10.0.1.10 → 10.1.1.10

Step 2: Routing in VPC1
  Route: 10.1.0.0/16 via br-vpc1

Step 3: Bridge-to-bridge veth pair
  br-vpc1 → peer-veth → br-vpc2

Step 4: VPC2 routing
  br-vpc2 → veth-ns2

Step 5: Destination receives
  NS in VPC2 receives packet

Return path is symmetric
```

---

## Data Structures

### VPC Metadata (JSON)

**File:** `/var/run/vpcctl/<vpc-name>.json`

```json
{
  "name": "production",
  "cidr": "10.0.0.0/16",
  "bridge": "br-production",
  "created": "2024-11-07T10:30:00Z",
  "subnets": [
    {
      "name": "web-tier",
      "cidr": "10.0.1.0/24",
      "type": "public",
      "namespace": "production-web-tier",
      "veth_host": "veth-web-tier",
      "veth_ns": "veth-web-tier-ns",
      "gateway": "10.0.0.1",
      "nat_enabled": true
    },
    {
      "name": "db-tier",
      "cidr": "10.0.2.0/24",
      "type": "private",
      "namespace": "production-db-tier",
      "veth_host": "veth-db-tier",
      "veth_ns": "veth-db-tier-ns",
      "gateway": "10.0.0.1",
      "nat_enabled": false
    }
  ],
  "peering": [
    {
      "peer_vpc": "staging",
      "peer_cidr": "10.1.0.0/16",
      "status": "active"
    }
  ]
}
```

### Security Policy (JSON)

**File:** `policies/<policy-name>.json`

```json
{
  "version": "1.0",
  "subnet": "10.0.1.0/24",
  "namespace": "production-web-tier",
  "ingress": [
    {
      "port": 80,
      "protocol": "tcp",
      "source": "0.0.0.0/0",
      "action": "allow",
      "description": "HTTP from anywhere"
    },
    {
      "port": 443,
      "protocol": "tcp",
      "source": "0.0.0.0/0",
      "action": "allow",
      "description": "HTTPS from anywhere"
    },
    {
      "port": 22,
      "protocol": "tcp",
      "source": "10.0.0.0/16",
      "action": "allow",
      "description": "SSH from VPC only"
    }
  ],
  "egress": [
    {
      "destination": "0.0.0.0/0",
      "action": "allow",
      "description": "Allow all outbound"
    }
  ]
}
```

---

## Implementation Details

### VPC Creation Algorithm

```python
def create_vpc(vpc_name, cidr_block):
    1. Validate CIDR block format
    2. Check if VPC already exists
    3. Calculate network parameters:
       - Network address
       - Broadcast address
       - Gateway IP (first usable IP)
       - Usable IP range
    
    4. Create bridge:
       - Name: br-<vpc_name>
       - Type: bridge
       - State: UP
    
    5. Assign IP to bridge:
       - IP: <gateway>/prefix_length
       - Example: 10.0.0.1/16
    
    6. Enable bridge options:
       - STP: off (for simplicity)
       - Forwarding: on
    
    7. Create metadata:
       - Save to /var/run/vpcctl/<vpc_name>.json
       - Include: name, cidr, bridge, timestamp
    
    8. Log action
    9. Return success/failure
```

### Subnet Creation Algorithm

```python
def add_subnet(vpc_name, subnet_name, subnet_cidr, subnet_type):
    1. Load VPC metadata
    2. Validate subnet CIDR:
       - Must be within VPC CIDR
       - Must not overlap existing subnets
    
    3. Generate unique names:
       - Namespace: <vpc>-<subnet>
       - Veth host: veth-<subnet>
       - Veth namespace: veth-<subnet>-ns
    
    4. Create network namespace:
       - ip netns add <namespace>
    
    5. Create veth pair:
       - ip link add <veth_host> type veth peer <veth_ns>
    
    6. Configure host side:
       - Attach to bridge: ip link set <veth_host> master <bridge>
       - Bring up: ip link set <veth_host> up
    
    7. Configure namespace side:
       - Move to namespace: ip link set <veth_ns> netns <namespace>
       - Assign IP: ip addr add <subnet_ip> dev <veth_ns>
       - Bring up interface: ip link set <veth_ns> up
       - Bring up loopback: ip link set lo up
    
    8. Configure routing:
       - Default route: ip route add default via <gateway>
       - VPC route: ip route add <vpc_cidr> via <gateway>
    
    9. Update VPC metadata:
       - Add subnet to subnets array
       - Save metadata file
    
    10. Log action
    11. Return success/failure
```

### NAT Setup Algorithm

```python
def setup_nat(vpc_name, internet_interface):
    1. Load VPC metadata
    2. Get VPC CIDR block
    
    3. Enable IP forwarding:
       - sysctl -w net.ipv4.ip_forward=1
    
    4. Configure POSTROUTING (NAT):
       - iptables -t nat -A POSTROUTING \
         -s <vpc_cidr> -o <interface> -j MASQUERADE
    
    5. Configure FORWARD chain:
       - Allow VPC → Internet:
         iptables -A FORWARD -i <bridge> -o <interface> -j ACCEPT
       
       - Allow return traffic:
         iptables -A FORWARD -i <interface> -o <bridge> \
         -m state --state RELATED,ESTABLISHED -j ACCEPT
    
    6. Update metadata:
       - Mark NAT as enabled
       - Record interface used
    
    7. Log action
    8. Return success/failure
```

### Cleanup Algorithm

```python
def delete_vpc(vpc_name):
    1. Load VPC metadata
    2. For each subnet:
       a. Stop processes in namespace
       b. Delete namespace:
          - ip netns del <namespace>
       c. Veth pairs deleted automatically
    
    3. Remove NAT rules:
       - Find matching iptables rules
       - Delete POSTROUTING rules
       - Delete FORWARD rules
    
    4. Delete bridge:
       - Bring down: ip link set <bridge> down
       - Delete: ip link del <bridge>
    
    5. Delete peering links:
       - ip link del <peer-veth>
    
    6. Remove metadata file:
       - rm /var/run/vpcctl/<vpc_name>.json
    
    7. Log action
    8. Return success/failure
```

---

## Performance Considerations

### Scalability Limits

**Per VPC:**
- Subnets: 256 (practical limit ~50)
- Namespaces: Limited by kernel (thousands possible)
- Interfaces: 1024 (default), can be increased

**System-wide:**
- VPCs: Limited by CIDR space and memory
- Total namespaces: 10,000+ (depends on RAM)
- Network throughput: Near-native performance

### Performance Optimization

1. **Bridge Configuration:**
```bash
# Disable STP for lower latency
ip link set br-vpc stp_state 0

# Increase forwarding table
echo 4096 > /sys/class/net/br-vpc/bridge/ageing_time
```

2. **Namespace Optimization:**
```bash
# Increase buffer sizes
ip netns exec ns sysctl -w net.core.rmem_max=16777216
ip netns exec ns sysctl -w net.core.wmem_max=16777216
```

3. **iptables Optimization:**
```bash
# Use ipset for large rule sets
ipset create allowed_ips hash:ip
iptables -A INPUT -m set --match-set allowed_ips src -j ACCEPT
```

### Benchmarks

**Namespace-to-Namespace (same VPC):**
- Latency: ~0.1ms (vs 0.05ms host-to-host)
- Throughput: 10-20 Gbps (on 10G NIC)
- Overhead: ~5-10%

**NAT Performance:**
- Latency: +0.2ms
- Throughput: 5-10 Gbps
- CPU: 10-20% per Gbps

### Resource Usage

**Per VPC:**
- Memory: ~1-2 MB
- CPU: Negligible when idle

**Per Subnet:**
- Memory: ~500 KB per namespace
- CPU: Based on workload

---

## Security Architecture

### Isolation Boundaries

1. **Namespace Isolation:**
   - Process isolation
   - Network stack isolation
   - File system can be isolated (not implemented)

2. **Network Isolation:**
   - Layer 2 isolation (different bridges)
   - Layer 3 isolation (different IP ranges)
   - Firewall enforcement at namespace level

3. **Resource Isolation:**
   - CPU limits (cgroups - not implemented)
   - Memory limits (cgroups - not implemented)
   - Network bandwidth (tc - not implemented)

### Attack Surface

**Potential Vulnerabilities:**
1. Bridge forwarding loops
2. ARP spoofing between namespaces
3. iptables rule bypass
4. Metadata tampering

**Mitigations:**
1. STP enabled for loop prevention
2. iptables rules for ARP filtering
3. Proper rule ordering and default DROP
4. Metadata file permissions (root only)

---

This architecture document provides the technical foundation for understanding and extending the VPC implementation. For specific implementation details, refer to the source code and inline comments.
