# VPC Implementation on Linux

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Linux](https://img.shields.io/badge/platform-Linux-yellow.svg)
![Python](https://img.shields.io/badge/python-3.8%2B-blue.svg)

A complete Virtual Private Cloud (VPC) implementation using Linux networking primitives including network namespaces, veth pairs, bridges, and iptables.

## ��� Overview

This project recreates the fundamentals of a cloud VPC entirely on Linux. Using native networking tools, it provides VPC functionality including:

- **Multiple Isolated VPCs** with configurable CIDR ranges
- **Subnet Management** (public and private subnets)
- **Inter-subnet Routing** within VPCs
- **NAT Gateway** for internet access from public subnets
- **VPC Isolation** - VPCs cannot communicate by default
- **VPC Peering** - controlled inter-VPC communication
- **Security Groups** - firewall rules using iptables
- **Complete Automation** via CLI tool

## ��� Table of Contents

- [Features](#features)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Usage](#usage)
- [Testing](#testing)
- [Project Structure](#project-structure)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)
- [License](#license)

## ✨ Features

### Core Features

- ✅ **VPC Creation & Management** - Create isolated virtual networks with custom CIDR blocks
- ✅ **Subnet Provisioning** - Add multiple subnets (public/private) to VPCs
- ✅ **Automatic Routing** - Inter-subnet routing configured automatically
- ✅ **NAT Gateway** - Public subnets can access the internet
- ✅ **VPC Isolation** - Complete network isolation between VPCs
- ✅ **VPC Peering** - Selective inter-VPC communication
- ✅ **Security Groups** - JSON-based firewall policies
- ✅ **Lifecycle Management** - Clean creation, inspection, and deletion
- ✅ **Logging** - Comprehensive action logging

### Technical Implementation

- Network Namespaces for subnet isolation
- Linux Bridge as VPC router
- Veth pairs for namespace connectivity
- iptables for NAT and firewall rules
- JSON-based metadata storage
- Idempotent operations

## ���️ Architecture

```
                          Internet
                             ↑
                             |
                     [NAT Gateway]
                             |
                    [Host: eth0/wlan0]
                             |
              ┌──────────────┴──────────────┐
              │                             │
        [VPC 1: 10.0.0.0/16]         [VPC 2: 10.1.0.0/16]
              │                             │
        [Bridge: br-vpc1]            [Bridge: br-vpc2]
              │                             │
    ┌─────────┼─────────┐                   │
    │         │         │                   │
[veth]    [veth]    [veth]              [veth]
    │         │         │                   │
[Public]  [Private] [App]              [Public]
  NS        NS        NS                 NS
10.0.1.x  10.0.2.x  10.0.3.x          10.1.1.x
```

### Component Breakdown

| Component | Purpose | Implementation |
|-----------|---------|----------------|
| **VPC** | Isolated network | Linux Bridge |
| **Subnet** | Network segment | Network Namespace |
| **Connection** | Link subnets to VPC | Veth pair |
| **Router** | Route between subnets | Bridge forwarding |
| **NAT Gateway** | Internet access | iptables MASQUERADE |
| **Security Group** | Firewall rules | iptables chains |
| **Peering** | Inter-VPC link | Veth pair + routes |

## ��� Prerequisites

### System Requirements

- **OS**: Linux (Ubuntu 20.04+, Debian 10+, CentOS 8+, or similar)
- **Kernel**: 3.8+ (for network namespace support)
- **RAM**: 2GB minimum
- **Privileges**: sudo/root access required

### Required Packages

```bash
# Ubuntu/Debian
sudo apt-get update
sudo apt-get install -y iproute2 iptables bridge-utils python3 jq curl

# CentOS/RHEL
sudo yum install -y iproute iptables bridge-utils python3 jq curl

# Arch Linux
sudo pacman -S iproute2 iptables bridge-utils python jq curl
```

### Verify Installation

```bash
# Check required commands
ip --version          # iproute2
iptables --version    # netfilter
python3 --version     # Python 3.8+
jq --version          # JSON processor
```

## ��� Installation

### 1. Clone the Repository

```bash
git clone https://github.com/Nicholasojinni/linux-vpc-implementation.git
cd vpc-project
```

### 2. Make Scripts Executable

```bash
chmod +x vpcctl
chmod +x scripts/*.sh
chmod +x *.sh
```

### 3. Enable IP Forwarding

```bash
# Temporary (current session)
sudo sysctl -w net.ipv4.ip_forward=1

# Permanent (survives reboot)
echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
```

### 4. Create Required Directories

```bash
mkdir -p logs policies tests
sudo mkdir -p /var/run/vpcctl
```

## ��� Quick Start

### Basic VPC Setup (5 minutes)

```bash
# 1. Create a VPC
sudo ./vpcctl create-vpc myvpc 10.0.0.0/16

# 2. Add a public subnet
sudo ./vpcctl add-subnet myvpc public-subnet 10.0.1.0/24 public

# 3. Add a private subnet
sudo ./vpcctl add-subnet myvpc private-subnet 10.0.2.0/24 private

# 4. Enable internet access (replace eth0 with your interface)
sudo ./vpcctl setup-nat myvpc eth0

# 5. Verify setup
sudo ./vpcctl list
```

### Deploy Test Application

```bash
# Deploy web server in public subnet
./deploy-server.sh myvpc-public-subnet 8080

# Test from within the namespace
sudo ip netns exec myvpc-public-subnet curl localhost:8080

# Test connectivity
sudo ip netns exec myvpc-public-subnet ping -c 3 8.8.8.8
```

### Cleanup

```bash
# Delete specific VPC
sudo ./vpcctl delete-vpc myvpc

# Or clean everything
./cleanup-all.sh
```

## ��� Usage

### Command Reference

#### Create VPC

```bash
./vpcctl create-vpc <vpc-name> <cidr-block>

# Example
sudo ./vpcctl create-vpc production 10.0.0.0/16
```

**What it does:**
- Creates a Linux bridge named `br-<vpc-name>`
- Assigns the first IP in the range as gateway
- Saves VPC metadata to `/var/run/vpcctl/<vpc-name>.json`

#### Add Subnet

```bash
./vpcctl add-subnet br-demo <subnet-name> <cidr-block> <type>

# Examples
sudo ./vpcctl add-subnet production web-subnet 10.0.1.0/24 public
sudo ./vpcctl add-subnet production db-subnet 10.0.2.0/24 private
```

**What it does:**
- Creates network namespace `<vpc-name>-<subnet-name>`
- Creates veth pair connecting namespace to bridge
- Configures IP addressing and routing
- Updates VPC metadata

#### Setup NAT Gateway

```bash
./vpcctl setup-nat br-demo [internet-interface]

# Example
sudo ./vpcctl setup-nat production eth0
```

**What it does:**
- Enables IP forwarding
- Configures iptables MASQUERADE for NAT
- Sets up FORWARD chain rules
- Allows outbound internet access

#### List VPCs

```bash
./vpcctl list

# Output shows:
# - VPC names and CIDR blocks
# - Bridge interfaces
# - All subnets with their details
```

#### Delete VPC

```bash
./vpcctl delete-vpc <vpc-name>

# Example
sudo ./vpcctl delete-vpc production
```

**What it does:**
- Deletes all network namespaces
- Removes veth pairs
- Deletes bridge interface
- Cleans up iptables rules
- Removes metadata files

### Advanced Usage

#### VPC Peering

```bash
# Create two VPCs
sudo ./vpcctl create-vpc vpc1 10.0.0.0/16
sudo ./vpcctl create-vpc vpc2 10.1.0.0/16

# Add subnets
sudo ./vpcctl add-subnet vpc1 subnet1 10.0.1.0/24 public
sudo ./vpcctl add-subnet vpc2 subnet2 10.1.1.0/24 public

# Establish peering
./setup-peering.sh vpc1 vpc2 10.0.0.0/16 10.1.0.0/16

# Test connectivity
sudo ip netns exec vpc1-subnet1 ping -c 3 10.1.1.10
```

#### Security Group Policies

Create policy file `policies/web-server-policy.json`:

```json
{
  "subnet": "10.0.1.0/24",
  "namespace": "production-web-subnet",
  "ingress": [
    {"port": 80, "protocol": "tcp", "action": "allow", "description": "HTTP"},
    {"port": 443, "protocol": "tcp", "action": "allow", "description": "HTTPS"},
    {"port": 22, "protocol": "tcp", "action": "deny", "description": "SSH"}
  ]
}
```

Apply policy:

```bash
./apply-policy.sh policies/web-server-policy.json
```

#### Execute Commands in Namespace

```bash
# General syntax
sudo ip netns exec <namespace-name> <command>

# Examples
sudo ip netns exec myvpc-public-subnet ip addr show
sudo ip netns exec myvpc-public-subnet ip route
sudo ip netns exec myvpc-public-subnet iptables -L
sudo ip netns exec myvpc-public-subnet bash  # Interactive shell
```

## ��� Testing

### Run Test Suite

```bash
# Run all tests
./run-tests.sh

# Tests include:
# - VPC creation verification
# - Intra-VPC connectivity
# - Internet access from public subnet
# - VPC isolation
# - Web server deployment
# - NAT functionality
```

### Manual Testing

#### Test 1: Subnet Communication

```bash
# Public → Private subnet
sudo ip netns exec myvpc-public-subnet ping -c 3 10.0.2.10

# Private → Public subnet
sudo ip netns exec myvpc-private-subnet ping -c 3 10.0.1.10
```

#### Test 2: Internet Access

```bash
# Should succeed (public subnet with NAT)
sudo ip netns exec myvpc-public-subnet ping -c 3 8.8.8.8
sudo ip netns exec myvpc-public-subnet curl -I https://google.com

# Should fail (private subnet without NAT)
sudo ip netns exec myvpc-private-subnet ping -c 2 8.8.8.8 -W 2
```

#### Test 3: VPC Isolation

```bash
# Create second VPC
sudo ./vpcctl create-vpc vpc2 10.1.0.0/16
sudo ./vpcctl add-subnet vpc2 subnet2 10.1.1.0/24 public

# Try to reach from first VPC (should fail)
sudo ip netns exec myvpc-public-subnet ping -c 2 10.1.1.10 -W 2
# Expected: 100% packet loss
```

#### Test 4: Security Groups

```bash
# Deploy server on port 80
sudo ip netns exec myvpc-public-subnet python3 -m http.server 80 &

# Apply policy blocking port 80
./apply-policy.sh policies/block-http.json

# Test (should timeout)
sudo ip netns exec myvpc-public-subnet curl -s localhost:80 --max-time 3
```

### Performance Testing

```bash
# Bandwidth test between namespaces
sudo ip netns exec myvpc-public-subnet iperf3 -s &
sudo ip netns exec myvpc-private-subnet iperf3 -c 10.0.1.10

# Latency test
sudo ip netns exec myvpc-public-subnet ping -c 100 10.0.2.10 | tail -n 1
```

## ��� Project Structure

```
vpc-project/
│
├── vpcctl                      # Main CLI tool
├── deploy-server.sh            # Deploy test web servers
├── apply-policy.sh             # Apply security group policies
├── setup-peering.sh            # Configure VPC peering
├── cleanup-all.sh              # Complete cleanup script
├── run-tests.sh                # Automated test suite
│
├── policies/                   # Security group policies
│   ├── public-subnet-policy.json
│   ├── private-subnet-policy.json
│   └── web-server-policy.json
│
├── logs/                       # Log files
│   └── vpcctl.log
│
├── scripts/                    # Additional utility scripts
│   ├── monitor-vpc.sh
│   └── backup-config.sh
│
├── tests/                      # Test files
│   └── integration-tests.sh
│
├── docs/                       # Documentation
│   ├── ARCHITECTURE.md
│   ├── TROUBLESHOOTING.md
│   └── API.md
│
├── README.md                   # This file
├── LICENSE                     # MIT License
└── .gitignore                  # Git ignore rules
```

### Key Files

| File | Description |
|------|-------------|
| `vpcctl` | Main CLI tool for VPC management |
| `/var/run/vpcctl/*.json` | VPC metadata storage |
| `logs/vpcctl.log` | Operation logs |
| `policies/*.json` | Security group definitions |

## ��� Troubleshooting

### Common Issues

#### Issue: "Operation not permitted"

**Solution:** Ensure you're using `sudo` for all `vpcctl` commands.

```bash
sudo ./vpcctl create-vpc myvpc 10.0.0.0/16
```

#### Issue: "Cannot create bridge: File exists"

**Solution:** Bridge already exists. Delete it first.

```bash
sudo ip link del br-myvpc
sudo ./vpcctl create-vpc myvpc 10.0.0.0/16
```

#### Issue: No internet access from namespace

**Checklist:**

```bash
# 1. Verify IP forwarding is enabled
cat /proc/sys/net/ipv4/ip_forward  # Should output: 1

# 2. Check NAT rules
sudo iptables -t nat -L -n -v | grep MASQUERADE

# 3. Verify your internet interface
ip route | grep default

# 4. Check namespace routes
sudo ip netns exec myvpc-public-subnet ip route
```

#### Issue: Cannot ping between subnets

**Solution:**

```bash
# Check if bridge is up
ip link show br-myvpc | grep "state UP"

# Verify veth pairs are connected
bridge link show

# Check namespace IPs
sudo ip netns exec myvpc-public-subnet ip addr
```

#### Issue: DNS resolution fails in namespace

**Solution:** Add DNS server to namespace.

```bash
sudo mkdir -p /etc/netns/myvpc-public-subnet
echo "nameserver 8.8.8.8" | sudo tee /etc/netns/myvpc-public-subnet/resolv.conf
```

### Debug Commands

```bash
# List all namespaces
sudo ip netns list

# List all bridges
brctl show  # or: bridge link show

# Show iptables rules
sudo iptables -L -n -v
sudo iptables -t nat -L -n -v

# Show routes in namespace
sudo ip netns exec <namespace> ip route

# Show interfaces in namespace
sudo ip netns exec <namespace> ip link show

# Monitor network traffic
sudo ip netns exec <namespace> tcpdump -i any
```

### Getting Help

```bash
# Show help
./vpcctl help

# Check logs
tail -f logs/vpcctl.log

# View VPC details
cat /var/run/vpcctl/br-demo.json | jq
```

## ��� Demo

[https://drive.google.com/file/d/1UGRdnNnnhlovnby0UI43sFy1UwzdRTnd/view?usp=sharing]

## ��� Blog Post

Read the complete tutorial: [https://medium.com/@ojinnin/building-your-own-virtual-private-cloud-vpc-on-linux-from-scratch-a4ca47a08adf]

## ��� Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

### Development Setup

```bash
# Fork and clone the repo
git clone https://github.com/Nicholasojinni/linux-vpc-implementation.git
cd vpc-project

# Create a feature branch
git checkout -b feature/your-feature-name

# Make your changes and test
./run-tests.sh

# Commit and push
git commit -am "Add your feature"
git push origin feature/your-feature-name
```

## ��� License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## ��� Author

**Your Name**

- GitHub: [https://github.com/Nicholasojinni]
- LinkedIn: [https://www.linkedin.com/in/ojinni-oluwafemi11/]
- Blog: [https://https://medium.com/@ojinnin/building-your-own-virtual-private-cloud-vpc-on-linux-from-scratch-a4ca47a08adf]

## ��� Acknowledgments

- HNG Internship Program
- Linux Network Namespace documentation
- iptables community resources

## ��� Additional Resources

- [HNG Internship](https://hng.tech/internship)
- [HNG Premium](https://hng.tech/premium)
- [HNG Hire](https://hng.tech/hire)
- [Linux Network Namespaces](https://man7.org/linux/man-pages/man8/ip-netns.8.html)
- [iptables Tutorial](https://www.netfilter.org/documentation/HOWTO/NAT-HOWTO.html)

---

⭐ **Star this repo** if you found it helpful!

��� **Found a bug?** [Open an issue](https://github.com/Nicholasojinni/vpc-project/issues)

��� **Have a suggestion?** [Start a discussion](https://github.com/Nicholasojinni/vpc-project/discussions)
