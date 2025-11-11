#!/bin/bash
#
# setup-peering.sh - Establish VPC peering connection
# Usage: ./setup-peering.sh <vpc1-name> <vpc2-name> <vpc1-cidr> <vpc2-cidr>
#

set -e

if [ $# -lt 4 ]; then
    echo "Usage: $0 <vpc1-name> <vpc2-name> <vpc1-cidr> <vpc2-cidr>"
    echo "Example: $0 myvpc vpc2 10.0.0.0/16 10.1.0.0/16"
    exit 1
fi

VPC1=$1
VPC2=$2
VPC1_CIDR=$3
VPC2_CIDR=$4

BRIDGE1="br-${VPC1}"
BRIDGE2="br-${VPC2}"
PEER1="peer-${VPC1}-${VPC2}"
PEER2="peer-${VPC2}-${VPC1}"
LOG_DIR="logs"
LOG_FILE="$LOG_DIR/peering.log"

# Create logs directory
mkdir -p "$LOG_DIR"

# Function to log messages
log() {
    echo "[setup-peering] $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

log "========================================"
log "Setting up VPC peering"
log "VPC 1: $VPC1 ($VPC1_CIDR)"
log "VPC 2: $VPC2 ($VPC2_CIDR)"
log "========================================"

# Validate VPCs exist
if ! ip link show "$BRIDGE1" &> /dev/null; then
    log "ERROR: VPC '$VPC1' (bridge: $BRIDGE1) does not exist"
    exit 1
fi

if ! ip link show "$BRIDGE2" &> /dev/null; then
    log "ERROR: VPC '$VPC2' (bridge: $BRIDGE2) does not exist"
    exit 1
fi

# Check if peering already exists
if ip link show "$PEER1" &> /dev/null; then
    log "WARNING: Peering link $PEER1 already exists"
    read -p "Do you want to delete and recreate it? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log "Deleting existing peering link..."
        sudo ip link del "$PEER1" 2>/dev/null || true
    else
        log "Keeping existing peering. Exiting."
        exit 0
    fi
fi

# Validate CIDR format
validate_cidr() {
    local cidr=$1
    if [[ ! $cidr =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
        log "ERROR: Invalid CIDR format: $cidr"
        exit 1
    fi
}

validate_cidr "$VPC1_CIDR"
validate_cidr "$VPC2_CIDR"

# Check for CIDR overlap (warning only)
if [ "$VPC1_CIDR" == "$VPC2_CIDR" ]; then
    log "WARNING: VPC CIDRs overlap! This may cause routing issues."
    log "VPC1: $VPC1_CIDR"
    log "VPC2: $VPC2_CIDR"
    read -p "Continue anyway? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Create veth pair for peering
log "Creating veth pair for peering..."
log "  Interface 1: $PEER1 (attached to $BRIDGE1)"
log "  Interface 2: $PEER2 (attached to $BRIDGE2)"

sudo ip link add "$PEER1" type veth peer name "$PEER2"
if [ $? -ne 0 ]; then
    log "ERROR: Failed to create veth pair"
    exit 1
fi
log "✓ Veth pair created"

# Attach peer interfaces to respective bridges
log "Attaching peering interfaces to bridges..."

sudo ip link set "$PEER1" master "$BRIDGE1"
if [ $? -ne 0 ]; then
    log "ERROR: Failed to attach $PEER1 to $BRIDGE1"
    sudo ip link del "$PEER1"
    exit 1
fi
log "✓ $PEER1 attached to $BRIDGE1"

sudo ip link set "$PEER2" master "$BRIDGE2"
if [ $? -ne 0 ]; then
    log "ERROR: Failed to attach $PEER2 to $BRIDGE2"
    sudo ip link del "$PEER1"
    exit 1
fi
log "✓ $PEER2 attached to $BRIDGE2"

# Bring up peering interfaces
log "Bringing up peering interfaces..."
sudo ip link set "$PEER1" up
sudo ip link set "$PEER2" up
log "✓ Peering interfaces are up"

# Get bridge gateway IPs
VPC1_GW=$(ip addr show "$BRIDGE1" | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1 | head -n 1)
VPC2_GW=$(ip addr show "$BRIDGE2" | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1 | head -n 1)

if [ -z "$VPC1_GW" ] || [ -z "$VPC2_GW" ]; then
    log "ERROR: Could not determine gateway IPs for bridges"
    log "VPC1 Gateway: $VPC1_GW"
    log "VPC2 Gateway: $VPC2_GW"
    exit 1
fi

log "Gateway IPs:"
log "  $BRIDGE1: $VPC1_GW"
log "  $BRIDGE2: $VPC2_GW"

# Add routing entries on host
log "Adding routing entries on host..."

# Route to VPC2 network via VPC1 bridge
if ip route | grep -q "^${VPC2_CIDR} "; then
    log "Route to $VPC2_CIDR already exists, replacing..."
    sudo ip route del "$VPC2_CIDR" 2>/dev/null || true
fi
sudo ip route add "$VPC2_CIDR" via "$VPC1_GW" dev "$BRIDGE1" 2>/dev/null || log "Note: Route to $VPC2_CIDR may already exist"
log "✓ Added route: $VPC2_CIDR via $VPC1_GW dev $BRIDGE1"

# Route to VPC1 network via VPC2 bridge
if ip route | grep -q "^${VPC1_CIDR} "; then
    log "Route to $VPC1_CIDR already exists, replacing..."
    sudo ip route del "$VPC1_CIDR" 2>/dev/null || true
fi
sudo ip route add "$VPC1_CIDR" via "$VPC2_GW" dev "$BRIDGE2" 2>/dev/null || log "Note: Route to $VPC1_CIDR may already exist"
log "✓ Added route: $VPC1_CIDR via $VPC2_GW dev $BRIDGE2"

# Add routes in all namespaces of each VPC
log "Adding routes in VPC namespaces..."

# VPC1 namespaces - add route to VPC2 network
for ns in $(sudo ip netns list | grep "^${VPC1}-" | awk '{print $1}'); do
    sudo ip netns exec "$ns" ip route add "$VPC2_CIDR" via "$VPC1_GW" 2>/dev/null || true
    log "  ✓ Added route to $VPC2_CIDR in namespace: $ns"
done

# VPC2 namespaces - add route to VPC1 network
for ns in $(sudo ip netns list | grep "^${VPC2}-" | awk '{print $1}'); do
    sudo ip netns exec "$ns" ip route add "$VPC1_CIDR" via "$VPC2_GW" 2>/dev/null || true
    log "  ✓ Added route to $VPC1_CIDR in namespace: $ns"
done

# Enable forwarding between bridges (should already be enabled, but ensure)
log "Ensuring IP forwarding is enabled..."
sudo sysctl -w net.ipv4.ip_forward=1 > /dev/null

# Add iptables rules to allow forwarding between VPCs
log "Configuring firewall rules for peering..."
sudo iptables -A FORWARD -i "$BRIDGE1" -o "$BRIDGE2" -j ACCEPT 2>/dev/null || log "Note: Forward rule may already exist"
sudo iptables -A FORWARD -i "$BRIDGE2" -o "$BRIDGE1" -j ACCEPT 2>/dev/null || log "Note: Forward rule may already exist"
log "✓ Firewall rules configured"

# Summary
log ""
log "========================================"
log "✓ VPC Peering Setup Complete!"
log "========================================"
log "VPC 1: $VPC1 ($VPC1_CIDR) <--> VPC 2: $VPC2 ($VPC2_CIDR)"
log ""
log "Bridge connections:"
log "  $BRIDGE1 <-- $PEER1 <--> $PEER2 --> $BRIDGE2"
log ""
log "Test connectivity with:"
log "  # Get an IP from VPC2"
log "  VPC2_IP=\$(sudo ip netns exec ${VPC2}-<subnet-name> ip addr | grep 'inet ' | awk '{print \$2}' | cut -d'/' -f1)"
log "  # Ping from VPC1"
log "  sudo ip netns exec ${VPC1}-<subnet-name> ping -c 3 \$VPC2_IP"
log ""

# Save peering info
PEERING_INFO="$LOG_DIR/peering_${VPC1}_${VPC2}.json"
cat > "$PEERING_INFO" <<EOF
{
  "vpc1": {
    "name": "$VPC1",
    "cidr": "$VPC1_CIDR",
    "bridge": "$BRIDGE1",
    "gateway": "$VPC1_GW",
    "peer_interface": "$PEER1"
  },
  "vpc2": {
    "name": "$VPC2",
    "cidr": "$VPC2_CIDR",
    "bridge": "$BRIDGE2",
    "gateway": "$VPC2_GW",
    "peer_interface": "$PEER2"
  },
  "established": "$(date -Iseconds)",
  "status": "active"
}
EOF

log "Peering information saved to: $PEERING_INFO"
log ""
log "To remove this peering, run:"
log "  sudo ip link del $PEER1"
log "  sudo ip route del $VPC2_CIDR"
log "  sudo ip route del $VPC1_CIDR"
