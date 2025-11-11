#!/bin/bash
#
# run-tests.sh - Comprehensive VPC testing suite
# Usage: ./run-tests.sh
#

set -e

LOG_DIR="logs"
LOG_FILE="$LOG_DIR/tests.log"
RESULTS_FILE="$LOG_DIR/test_results.txt"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test counters
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
SKIPPED_TESTS=0

# Create logs directory
mkdir -p "$LOG_DIR"

# Clear previous results
> "$RESULTS_FILE"

# Function to log messages
log() {
    echo "[tests] $1" | tee -a "$LOG_FILE"
}

# Function to print test header
print_header() {
    echo ""
    echo "========================================" | tee -a "$LOG_FILE"
    echo "$1" | tee -a "$LOG_FILE"
    echo "========================================" | tee -a "$LOG_FILE"
}

# Function to run a test
run_test() {
    local test_name="$1"
    local test_command="$2"
    local expected_result="$3" # "pass" or "fail"
    
    ((TOTAL_TESTS++))
    
    echo -n "Test $TOTAL_TESTS: $test_name ... " | tee -a "$LOG_FILE"
    
    # Run the command and capture output
    if eval "$test_command" > /tmp/test_output_$$ 2>&1; then
        actual_result="pass"
    else
        actual_result="fail"
    fi
    
    # Check if result matches expectation
    if [ "$actual_result" == "$expected_result" ]; then
        echo -e "${GREEN}✓ PASSED${NC}" | tee -a "$LOG_FILE"
        echo "PASS: $test_name" >> "$RESULTS_FILE"
        ((PASSED_TESTS++))
        return 0
    else
        echo -e "${RED}✗ FAILED${NC}" | tee -a "$LOG_FILE"
        echo "FAIL: $test_name" >> "$RESULTS_FILE"
        echo "  Expected: $expected_result, Got: $actual_result" | tee -a "$LOG_FILE"
        cat /tmp/test_output_$$ | head -n 5 | sed 's/^/  /' | tee -a "$LOG_FILE"
        ((FAILED_TESTS++))
        return 1
    fi
    
    rm -f /tmp/test_output_$$
}

# Function to check if a VPC exists
vpc_exists() {
    local vpc_name="$1"
    [ -f "/var/run/vpcctl/${vpc_name}.json" ]
}

# Function to check if namespace exists
namespace_exists() {
    local ns_name="$1"
    sudo ip netns list | grep -q "^${ns_name}"
}

# Start tests
print_header "VPC Testing Suite - $(date)"

# Pre-flight checks
print_header "Pre-flight Checks"

log "Checking prerequisites..."
if ! command -v sudo &> /dev/null; then
    log "ERROR: sudo not found"
    exit 1
fi

if ! command -v ip &> /dev/null; then
    log "ERROR: ip command not found"
    exit 1
fi

if [ ! -f "./vpcctl" ]; then
    log "ERROR: vpcctl not found in current directory"
    exit 1
fi

log "✓ All prerequisites met"

# Test Group 1: VPC Creation and Management
print_header "Test Group 1: VPC Creation and Management"

TEST_VPC1="test-vpc1"
TEST_VPC2="test-vpc2"

run_test "Create first VPC" \
    "sudo ./vpcctl create-vpc $TEST_VPC1 10.0.0.0/16" \
    "pass"

run_test "VPC metadata file exists" \
    "[ -f /var/run/vpcctl/${TEST_VPC1}.json ]" \
    "pass"

run_test "Bridge created for VPC" \
    "ip link show br-${TEST_VPC1}" \
    "pass"

run_test "List VPCs shows created VPC" \
    "sudo ./vpcctl list | grep -q $TEST_VPC1" \
    "pass"

# Test Group 2: Subnet Management
print_header "Test Group 2: Subnet Management"

run_test "Add public subnet to VPC" \
    "sudo ./vpcctl add-subnet $TEST_VPC1 public-subnet 10.0.1.0/24 public" \
    "pass"

run_test "Public subnet namespace created" \
    "sudo ip netns list | grep -q '${TEST_VPC1}-public-subnet'" \
    "pass"

run_test "Add private subnet to VPC" \
    "sudo ./vpcctl add-subnet $TEST_VPC1 private-subnet 10.0.2.0/24 private" \
    "pass"

run_test "Private subnet namespace created" \
    "sudo ip netns list | grep -q '${TEST_VPC1}-private-subnet'" \
    "pass"

run_test "Subnet has IP address assigned" \
    "sudo ip netns exec ${TEST_VPC1}-public-subnet ip addr show | grep -q '10.0.1.10'" \
    "pass"

run_test "Subnet has loopback interface" \
    "sudo ip netns exec ${TEST_VPC1}-public-subnet ip addr show lo | grep -q 'state UNKNOWN'" \
    "pass"

# Test Group 3: Routing and Connectivity
print_header "Test Group 3: Routing and Connectivity"

run_test "Subnet has default route" \
    "sudo ip netns exec ${TEST_VPC1}-public-subnet ip route | grep -q 'default via'" \
    "pass"

run_test "Loopback connectivity in namespace" \
    "sudo ip netns exec ${TEST_VPC1}-public-subnet ping -c 1 127.0.0.1 -W 2" \
    "pass"

run_test "Ping between public and private subnets" \
    "sudo ip netns exec ${TEST_VPC1}-public-subnet ping -c 3 10.0.2.10 -W 5" \
    "pass"

run_test "Ping from private to public subnet" \
    "sudo ip netns exec ${TEST_VPC1}-private-subnet ping -c 3 10.0.1.10 -W 5" \
    "pass"

# Test Group 4: NAT Gateway
print_header "Test Group 4: NAT Gateway and Internet Access"

# Find internet interface
INTERNET_IF=$(ip route | grep default | awk '{print $5}' | head -n 1)
log "Detected internet interface: $INTERNET_IF"

if [ -n "$INTERNET_IF" ]; then
    run_test "Setup NAT gateway" \
        "sudo ./vpcctl setup-nat $TEST_VPC1 $INTERNET_IF" \
        "pass"
    
    run_test "Public subnet can reach internet (ping)" \
        "sudo ip netns exec ${TEST_VPC1}-public-subnet ping -c 2 8.8.8.8 -W 5" \
        "pass"
    
    run_test "Public subnet DNS resolution" \
        "sudo ip netns exec ${TEST_VPC1}-public-subnet ping -c 1 google.com -W 5" \
        "pass"
else
    log "⚠ Warning: Could not detect internet interface, skipping NAT tests"
    ((SKIPPED_TESTS+=3))
fi

# Test Group 5: VPC Isolation
print_header "Test Group 5: VPC Isolation"

run_test "Create second VPC" \
    "sudo ./vpcctl create-vpc $TEST_VPC2 10.1.0.0/16" \
    "pass"

run_test "Add subnet to second VPC" \
    "sudo ./vpcctl add-subnet $TEST_VPC2 public-subnet2 10.1.1.0/24 public" \
    "pass"

run_test "VPCs are isolated (cannot ping)" \
    "sudo ip netns exec ${TEST_VPC1}-public-subnet ping -c 2 10.1.1.10 -W 3" \
    "fail"

# Test Group 6: Application Deployment
print_header "Test Group 6: Application Deployment"

if [ -f "./deploy-server.sh" ]; then
    run_test "Deploy web server in public subnet" \
        "./deploy-server.sh ${TEST_VPC1}-public-subnet 8080" \
        "pass"
    
    sleep 2
    
    run_test "Web server is accessible from within namespace" \
        "sudo ip netns exec ${TEST_VPC1}-public-subnet curl -s http://localhost:8080 | grep -q 'VPC Test Server'" \
        "pass"
    
    run_test "Web server accessible from other subnet in same VPC" \
        "sudo ip netns exec ${TEST_VPC1}-private-subnet curl -s http://10.0.1.10:8080 --max-time 5 | grep -q 'VPC'" \
        "pass"
else
    log "⚠ Warning: deploy-server.sh not found, skipping deployment tests"
    ((SKIPPED_TESTS+=3))
fi

# Test Group 7: Security Groups (if policy file exists)
print_header "Test Group 7: Security Groups"

if [ -f "./apply-policy.sh" ]; then
    # Create a test policy
    mkdir -p policies
    cat > policies/test-policy.json <<EOF
{
  "subnet": "10.0.1.0/24",
  "namespace": "${TEST_VPC1}-public-subnet",
  "ingress": [
    {"port": 8080, "protocol": "tcp", "action": "allow"},
    {"port": 9999, "protocol": "tcp", "action": "deny"}
  ]
}
EOF
    
    run_test "Apply security policy" \
        "./apply-policy.sh policies/test-policy.json" \
        "pass"
    
    run_test "Allowed port is accessible" \
        "sudo ip netns exec ${TEST_VPC1}-public-subnet iptables -L INPUT | grep -q 'tcp dpt:8080'" \
        "pass"
    
    run_test "Denied port is blocked" \
        "sudo ip netns exec ${TEST_VPC1}-public-subnet iptables -L INPUT | grep -q 'tcp dpt:9999'" \
        "pass"
else
    log "⚠ Warning: apply-policy.sh not found, skipping security tests"
    ((SKIPPED_TESTS+=3))
fi

# Test Group 8: VPC Peering
print_header "Test Group 8: VPC Peering"

if [ -f "./setup-peering.sh" ]; then
    run_test "Setup VPC peering" \
        "./setup-peering.sh $TEST_VPC1 $TEST_VPC2 10.0.0.0/16 10.1.0.0/16" \
        "pass"
    
    run_test "Peering link created" \
        "ip link show | grep -q 'peer-${TEST_VPC1}-${TEST_VPC2}'" \
        "pass"
    
    sleep 2
    
    run_test "Cross-VPC connectivity after peering" \
        "sudo ip netns exec ${TEST_VPC1}-public-subnet ping -c 3 10.1.1.10 -W 5" \
        "pass"
else
    log "⚠ Warning: setup-peering.sh not found, skipping peering tests"
    ((SKIPPED_TESTS+=3))
fi

# Test Group 9: Cleanup
print_header "Test Group 9: Cleanup Operations"

run_test "Delete first VPC" \
    "sudo ./vpcctl delete-vpc $TEST_VPC1" \
    "pass"

run_test "VPC metadata file removed" \
    "[ ! -f /var/run/vpcctl/${TEST_VPC1}.json ]" \
    "pass"

run_test "VPC namespaces removed" \
    "! sudo ip netns list | grep -q ${TEST_VPC1}" \
    "pass"

run_test "VPC bridge removed" \
    "! ip link show br-${TEST_VPC1} 2>/dev/null" \
    "pass"

# Clean up remaining test VPC
sudo ./vpcctl delete-vpc $TEST_VPC2 2>/dev/null || true

# Final cleanup
sudo pkill -f "python3 -m http.server" 2>/dev/null || true

# Print Summary
print_header "Test Summary"

echo "" | tee -a "$LOG_FILE"
echo "Total Tests:   $TOTAL_TESTS" | tee -a "$LOG_FILE"
echo -e "${GREEN}Passed:        $PASSED_TESTS${NC}" | tee -a "$LOG_FILE"
echo -e "${RED}Failed:        $FAILED_TESTS${NC}" | tee -a "$LOG_FILE"

if [ "$SKIPPED_TESTS" -gt 0 ]; then
    echo -e "${YELLOW}Skipped:       $SKIPPED_TESTS${NC}" | tee -a "$LOG_FILE"
fi

echo "" | tee -a "$LOG_FILE"

# Calculate success rate
if [ "$TOTAL_TESTS" -gt 0 ]; then
    SUCCESS_RATE=$((PASSED_TESTS * 100 / TOTAL_TESTS))
    echo "Success Rate:  ${SUCCESS_RATE}%" | tee -a "$LOG_FILE"
fi

echo "" | tee -a "$LOG_FILE"
echo "Detailed results saved to: $RESULTS_FILE" | tee -a "$LOG_FILE"
echo "Full log saved to: $LOG_FILE" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Exit with appropriate code
if [ "$FAILED_TESTS" -eq 0 ]; then
    echo -e "${GREEN}✓ All tests passed!${NC}" | tee -a "$LOG_FILE"
    exit 0
else
    echo -e "${RED}✗ Some tests failed${NC}" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    echo "Failed tests:" | tee -a "$LOG_FILE"
    grep "^FAIL:" "$RESULTS_FILE" | sed 's/^FAIL: /  - /' | tee -a "$LOG_FILE"
    exit 1
fi
