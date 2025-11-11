#!/bin/bash
#
# apply-policy.sh - Apply security group policy to network namespace
# Usage: ./apply-policy.sh <policy-file>
#

set -e

if [ $# -lt 1 ]; then
    echo "Usage: $0 <policy-file>"
    echo "Example: $0 policies/public-subnet-policy.json"
    exit 1
fi

POLICY_FILE=$1
LOG_DIR="logs"
LOG_FILE="$LOG_DIR/policy.log"

# Create logs directory
mkdir -p "$LOG_DIR"

# Function to log messages
log() {
    echo "[apply-policy] $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Check if policy file exists
if [ ! -f "$POLICY_FILE" ]; then
    log "ERROR: Policy file '$POLICY_FILE' not found"
    exit 1
fi

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    log "ERROR: jq is not installed"
    log "Install with: sudo apt-get install jq"
    exit 1
fi

# Validate JSON format
if ! jq empty "$POLICY_FILE" 2>/dev/null; then
    log "ERROR: Invalid JSON format in $POLICY_FILE"
    exit 1
fi

# Extract policy details
NAMESPACE=$(jq -r '.namespace' "$POLICY_FILE")
SUBNET=$(jq -r '.subnet' "$POLICY_FILE")

log "Applying security policy to namespace: $NAMESPACE"
log "Policy file: $POLICY_FILE"
log "Subnet: $SUBNET"

# Check if namespace exists
if ! sudo ip netns list | grep -q "^${NAMESPACE}"; then
    log "ERROR: Namespace '$NAMESPACE' does not exist"
    exit 1
fi

# Backup existing rules
log "Backing up existing iptables rules..."
sudo ip netns exec "$NAMESPACE" iptables-save > "$LOG_DIR/${NAMESPACE}_iptables_backup_$(date +%s).txt" 2>/dev/null || true

# Flush existing rules (optional, can be commented out)
log "Flushing existing INPUT chain rules..."
sudo ip netns exec "$NAMESPACE" iptables -F INPUT 2>/dev/null || true

# Set default policies
log "Setting default policies..."
sudo ip netns exec "$NAMESPACE" iptables -P INPUT DROP 2>/dev/null || log "Warning: Could not set INPUT policy"
sudo ip netns exec "$NAMESPACE" iptables -P FORWARD DROP 2>/dev/null || log "Warning: Could not set FORWARD policy"
sudo ip netns exec "$NAMESPACE" iptables -P OUTPUT ACCEPT 2>/dev/null || log "Warning: Could not set OUTPUT policy"

# Allow established connections
log "Allowing established and related connections..."
sudo ip netns exec "$NAMESPACE" iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow loopback
log "Allowing loopback traffic..."
sudo ip netns exec "$NAMESPACE" iptables -A INPUT -i lo -j ACCEPT

# Apply ingress rules
log "Applying ingress rules..."
RULE_COUNT=0

# Get number of ingress rules
INGRESS_COUNT=$(jq '.ingress | length' "$POLICY_FILE")

if [ "$INGRESS_COUNT" -gt 0 ]; then
    jq -c '.ingress[]' "$POLICY_FILE" | while read -r rule; do
        PORT=$(echo "$rule" | jq -r '.port')
        PROTOCOL=$(echo "$rule" | jq -r '.protocol')
        ACTION=$(echo "$rule" | jq -r '.action')
        DESC=$(echo "$rule" | jq -r '.description // "No description"')
        SOURCE=$(echo "$rule" | jq -r '.source // "0.0.0.0/0"')
        
        if [ "$ACTION" == "allow" ]; then
            if [ "$SOURCE" != "0.0.0.0/0" ]; then
                sudo ip netns exec "$NAMESPACE" iptables -A INPUT -p "$PROTOCOL" --dport "$PORT" -s "$SOURCE" -j ACCEPT
                log "  ✓ Allowed $PROTOCOL port $PORT from $SOURCE - $DESC"
            else
                sudo ip netns exec "$NAMESPACE" iptables -A INPUT -p "$PROTOCOL" --dport "$PORT" -j ACCEPT
                log "  ✓ Allowed $PROTOCOL port $PORT from anywhere - $DESC"
            fi
        elif [ "$ACTION" == "deny" ]; then
            if [ "$SOURCE" != "0.0.0.0/0" ]; then
                sudo ip netns exec "$NAMESPACE" iptables -A INPUT -p "$PROTOCOL" --dport "$PORT" -s "$SOURCE" -j DROP
                log "  ✓ Blocked $PROTOCOL port $PORT from $SOURCE - $DESC"
            else
                sudo ip netns exec "$NAMESPACE" iptables -A INPUT -p "$PROTOCOL" --dport "$PORT" -j DROP
                log "  ✓ Blocked $PROTOCOL port $PORT from anywhere - $DESC"
            fi
        else
            log "  ⚠ Unknown action '$ACTION' for rule: $DESC"
        fi
        
        ((RULE_COUNT++))
    done
else
    log "No ingress rules found in policy"
fi

# Apply egress rules if present
EGRESS_COUNT=$(jq '.egress | length' "$POLICY_FILE" 2>/dev/null || echo "0")

if [ "$EGRESS_COUNT" -gt 0 ]; then
    log "Applying egress rules..."
    jq -c '.egress[]' "$POLICY_FILE" | while read -r rule; do
        DESTINATION=$(echo "$rule" | jq -r '.destination // "0.0.0.0/0"')
        ACTION=$(echo "$rule" | jq -r '.action')
        DESC=$(echo "$rule" | jq -r '.description // "No description"')
        
        if [ "$ACTION" == "allow" ]; then
            sudo ip netns exec "$NAMESPACE" iptables -A OUTPUT -d "$DESTINATION" -j ACCEPT
            log "  ✓ Allowed outbound to $DESTINATION - $DESC"
        elif [ "$ACTION" == "deny" ]; then
            sudo ip netns exec "$NAMESPACE" iptables -A OUTPUT -d "$DESTINATION" -j DROP
            log "  ✓ Blocked outbound to $DESTINATION - $DESC"
        fi
    done
fi

# Display applied rules
log ""
log "Current iptables rules for $NAMESPACE:"
sudo ip netns exec "$NAMESPACE" iptables -L -n -v --line-numbers | while read -r line; do
    log "  $line"
done

log ""
log "✓ Policy applied successfully!"
log "Policy file: $POLICY_FILE"
log "Namespace: $NAMESPACE"
log "Total ingress rules: $INGRESS_COUNT"
log "Total egress rules: $EGRESS_COUNT"

# Save applied rules
log ""
log "Saving applied rules to: $LOG_DIR/${NAMESPACE}_iptables_applied.txt"
sudo ip netns exec "$NAMESPACE" iptables-save > "$LOG_DIR/${NAMESPACE}_iptables_applied.txt"

echo ""
echo "To verify the policy is working:"
echo "  sudo ip netns exec $NAMESPACE iptables -L -n -v"
echo ""
echo "To restore previous rules (if backed up):"
echo "  sudo ip netns exec $NAMESPACE iptables-restore < [backup-file]"
