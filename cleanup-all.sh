#!/bin/bash
#
# cleanup-all.sh - Complete cleanup of all VPC resources
# Usage: ./cleanup-all.sh [--force]
#

set -e

FORCE=false
if [ "$1" == "--force" ]; then
    FORCE=true
fi

LOG_DIR="logs"
LOG_FILE="$LOG_DIR/cleanup.log"

# Create logs directory
mkdir -p "$LOG_DIR"

# Function to log messages
log() {
    echo "[cleanup] $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

log "========================================"
log "VPC Cleanup Script"
log "========================================"

# Confirm cleanup unless --force is used
if [ "$FORCE" != true ]; then
    echo ""
    echo "This will delete ALL VPCs and related resources:"
    echo "  - All network namespaces"
    echo "  - All bridges"
    echo "  - All veth pairs"
    echo "  - All NAT rules"
    echo "  - All web servers"
    echo "  - All metadata files"
    echo ""
    read -p "Are you sure you want to continue? (yes/no): " -r
    echo
    if [ "$REPLY" != "yes" ]; then
        log "Cleanup cancelled by user"
        exit 0
    fi
fi

log "Starting cleanup process..."

# Step 1: Stop all web servers
log ""
log "Step 1: Stopping web servers..."
WEB_SERVERS=$(pgrep -f "python3 -m http.server" | wc -l)
if [ "$WEB_SERVERS" -gt 0 ]; then
    sudo pkill -f "python3 -m http.server" || true
    log "✓ Stopped $WEB_SERVERS web server(s)"
else
    log "No web servers running"
fi

# Clean up PID files
if [ -d "$LOG_DIR" ]; then
    rm -f "$LOG_DIR"/*.pid
    log "✓ Cleaned up PID files"
fi

# Step 2: Delete all VPCs using vpcctl
log ""
log "Step 2: Deleting VPCs via vpcctl..."
VPC_DIR="/var/run/vpcctl"
if [ -d "$VPC_DIR" ]; then
    VPC_COUNT=0
    for vpc_file in "$VPC_DIR"/*.json; do
        if [ -f "$vpc_file" ]; then
            vpc_name=$(basename "$vpc_file" .json)
            log "Deleting VPC: $vpc_name"
            if [ -f "./vpcctl" ]; then
                sudo ./vpcctl delete-vpc "$vpc_name" 2>&1 | while read -r line; do
                    log "  $line"
                done
            else
                log "  Warning: vpcctl not found, will clean manually"
            fi
            ((VPC_COUNT++))
        fi
    done
    
    if [ $VPC_COUNT -gt 0 ]; then
        log "✓ Deleted $VPC_COUNT VPC(s)"
    else
        log "No VPCs found in $VPC_DIR"
    fi
else
    log "VPC directory $VPC_DIR does not exist"
fi

# Step 3: Clean up any orphaned namespaces
log ""
log "Step 3: Cleaning orphaned namespaces..."
NAMESPACE_COUNT=0
sudo ip netns list 2>/dev/null | while read -r ns _; do
    if [ -n "$ns" ]; then
        log "Deleting namespace: $ns"
        sudo ip netns del "$ns" 2>/dev/null || log "  Warning: Could not delete $ns"
        ((NAMESPACE_COUNT++))
    fi
done

# Verify all namespaces are gone
REMAINING_NS=$(sudo ip netns list 2>/dev/null | wc -l)
if [ "$REMAINING_NS" -eq 0 ]; then
    log "✓ All namespaces cleaned"
else
    log "⚠ Warning: $REMAINING_NS namespace(s) still remain"
fi

# Step 4: Delete all bridges
log ""
log "Step 4: Deleting bridges..."
BRIDGE_COUNT=0
ip link show type bridge 2>/dev/null | grep "^[0-9]" | awk '{print $2}' | sed 's/:$//' | while read -r bridge; do
    # Only delete br-* bridges (our VPC bridges)
    if [[ $bridge == br-* ]]; then
        log "Deleting bridge: $bridge"
        sudo ip link set "$bridge" down 2>/dev/null || true
        sudo ip link del "$bridge" 2>/dev/null || log "  Warning: Could not delete $bridge"
        ((BRIDGE_COUNT++))
    fi
done

log "✓ Deleted VPC bridges"

# Step 5: Cleaning peering links...
log ""
log "Step 5: Cleaning peering links..."
PEER_COUNT=0

# Get unique peer links (only the base name, not both ends)
for link in $(ip link show 2>/dev/null | grep -oP 'peer-[^@:]+' | sort -u); do
    if ip link show "$link" &>/dev/null; then
        log "Deleting peering link: $link"
        sudo ip link del "$link" 2>/dev/null || true
        ((PEER_COUNT++))
    fi
done

if [ "$PEER_COUNT" -gt 0 ]; then
    log "✓ Deleted $PEER_COUNT peering link(s)"
else
    log "No peering links found"
fi



if [ "$PEER_COUNT" -gt 0 ]; then
    log "✓ Deleted $PEER_COUNT peering link(s)"
else
    log "No peering links found"
fi

# Step 6: Clean up NAT rules
log ""
log "Step 6: Cleaning NAT and firewall rules..."

# Save current rules for backup
BACKUP_FILE="$LOG_DIR/iptables_backup_$(date +%s).txt"
sudo iptables-save > "$BACKUP_FILE" 2>/dev/null || true
log "Backed up iptables to: $BACKUP_FILE"

# Flush NAT POSTROUTING chain (be careful here - only flush VPC-related rules)
log "Cleaning NAT POSTROUTING rules..."
# Instead of flushing everything, let's be selective
sudo iptables -t nat -S POSTROUTING | grep "MASQUERADE" | grep -E "10\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+" | while read -r rule; do
    # Convert -A to -D for deletion
    delete_rule=$(echo "$rule" | sed 's/^-A/-D/')
    sudo iptables -t nat $delete_rule 2>/dev/null || true
    log "  Removed NAT rule: $delete_rule"
done

# Clean FORWARD chain rules related to VPC bridges
log "Cleaning FORWARD rules..."
sudo iptables -S FORWARD | grep -E "br-" | while read -r rule; do
    delete_rule=$(echo "$rule" | sed 's/^-A/-D/')
    sudo iptables $delete_rule 2>/dev/null || true
    log "  Removed FORWARD rule: $delete_rule"
done

log "✓ Cleaned firewall rules"

# Step 7: Clean up metadata files
log ""
log "Step 7: Cleaning metadata files..."
if [ -d "$VPC_DIR" ]; then
    sudo rm -f "$VPC_DIR"/*.json
    log "✓ Cleaned VPC metadata files"
else
    log "No metadata directory found"
fi

# Clean up peering info files
if [ -d "$LOG_DIR" ]; then
    rm -f "$LOG_DIR"/peering_*.json
    log "✓ Cleaned peering metadata files"
fi

# Step 8: Clean up temporary web server files
log ""
log "Step 8: Cleaning temporary files..."
sudo rm -rf /tmp/webserver_* 2>/dev/null || true
log "✓ Cleaned temporary web server files"

# Step 9: Verify cleanup
log ""
log "Step 9: Verifying cleanup..."

ISSUES=0

# Check namespaces
NS_COUNT=$(sudo ip netns list 2>/dev/null | wc -l)
if [ "$NS_COUNT" -gt 0 ]; then
    log "⚠ Warning: $NS_COUNT namespace(s) still exist"
    sudo ip netns list | while read -r ns _; do
        log "    - $ns"
    done
    ((ISSUES++))
else
    log "✓ No namespaces remaining"
fi

# Check bridges
BRIDGE_COUNT=$(ip link show type bridge 2>/dev/null | grep -c "^[0-9]*: br-" || true)
if [ "$BRIDGE_COUNT" -gt 0 ]; then
    log "⚠ Warning: $BRIDGE_COUNT VPC bridge(s) still exist"
    ((ISSUES++))
else
    log "✓ No VPC bridges remaining"
fi

# Check peering links
PEER_COUNT=$(ip link show 2>/dev/null | grep -c "^[0-9]*: peer-" || true)
if [ "$PEER_COUNT" -gt 0 ]; then
    log "⚠ Warning: $PEER_COUNT peering link(s) still exist"
    ((ISSUES++))
else
    log "✓ No peering links remaining"
fi

# Check web servers
WEB_COUNT=$(pgrep -f "python3 -m http.server" 2>/dev/null | wc -l)
if [ "$WEB_COUNT" -gt 0 ]; then
    log "⚠ Warning: $WEB_COUNT web server(s) still running"
    ((ISSUES++))
else
    log "✓ No web servers running"
fi

# Summary
log ""
log "========================================"
if [ "$ISSUES" -eq 0 ]; then
    log "✓ CLEANUP COMPLETE!"
    log "All VPC resources have been removed"
else
    log "⚠ CLEANUP COMPLETED WITH WARNINGS"
    log "$ISSUES issue(s) detected (see above)"
    log ""
    log "You may need to manually clean up remaining resources"
fi
log "========================================"

# Final notes
log ""
log "Notes:"
log "  - Logs preserved in: $LOG_DIR/"
log "  - iptables backup saved to: $BACKUP_FILE"
log "  - IP forwarding is still enabled (net.ipv4.ip_forward=1)"
log ""

if [ "$ISSUES" -gt 0 ]; then
    log "To force manual cleanup of everything:"
    log "  sudo ip -all netns delete"
    log "  sudo iptables -F"
    log "  sudo iptables -t nat -F"
fi

echo ""
echo "Cleanup completed. Check $LOG_FILE for details."

exit 0
