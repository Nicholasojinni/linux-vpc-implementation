#!/bin/bash

# Function to show timestamped section headers
show_section() {
    echo ""
    echo "=========================================="
    echo "$(date '+%H:%M:%S') - $1"
    echo "=========================================="
    echo ""
    sleep 5  # Increased from 4 to 5 seconds
}

# Clean start
cd ~/vpc-project
./cleanup-all.sh --force
sleep 4  # Wait for cleanup to complete
clear

# ========================================
# Introduction (45 seconds)
# ========================================
show_section "Introduction: Linux VPC Implementation"
echo "Project: Building Virtual Private Cloud from Scratch"
echo "Using: Network Namespaces, Bridges, and iptables"
echo ""
sleep 6  # Time to introduce yourself

pwd
echo ""
sleep 3

echo "Project files:"
ls -la
sleep 6  # Time to explain the structure

show_section "CLI Tool Overview"
./vpcctl help
sleep 8  # Time to explain CLI commands

# ========================================
# Part 1: VPC Creation (1.5 minutes)
# ========================================
show_section "Part 1: Creating VPC with Subnets"
sleep 3

echo "Creating VPC 'demo' with CIDR 10.0.0.0/16..."
sleep 4  # Narrate what VPC is
sudo ./vpcctl create-vpc demo 10.0.0.0/16
sleep 5  # Explain what happened

echo ""
echo "Adding public subnet (10.0.1.0/24)..."
sleep 4  # Explain public subnet
sudo ./vpcctl add-subnet demo public 10.0.1.0/24 public
sleep 5  # Explain what was created

echo ""
echo "Adding private subnet (10.0.2.0/24)..."
sleep 4  # Explain private subnet
sudo ./vpcctl add-subnet demo private 10.0.2.0/24 private
sleep 5  # Explain differences

echo ""
echo "Listing all VPCs and subnets..."
sleep 3
sudo ./vpcctl list
sleep 7  # Time to explain the output details

# ========================================
# Part 2: NAT & Connectivity (2 minutes)
# ========================================
show_section "Part 2: NAT Gateway & Connectivity Tests"
sleep 3

echo "Setting up NAT gateway for internet access..."
sleep 4  # Explain what NAT does
sudo ./vpcctl setup-nat demo enp0s3
sleep 5  # Explain iptables rules created

echo ""
echo "Test 1: Ping bridge gateway (10.0.0.1)..."
sleep 4  # Explain what this test does
sudo ip netns exec demo-public ping -c 3 10.0.0.1
sleep 6  # Explain results

echo ""
echo "Test 2: Communication between subnets..."
echo "Pinging private subnet (10.0.0.12) from public subnet..."
sleep 4  # Explain inter-subnet routing
sudo ip netns exec demo-public ping -c 3 10.0.0.12
sleep 6  # Explain how bridge routes packets

echo ""
echo "Test 3: Internet access via NAT gateway..."
echo "Pinging Google DNS (8.8.8.8)..."
sleep 4  # Explain NAT translation
sudo ip netns exec demo-public ping -c 3 8.8.8.8
sleep 6  # Explain successful internet access

# ========================================
# Part 3: Application Deployment (1 minute)
# ========================================
show_section "Part 3: Web Application Deployment"
sleep 3

echo "Deploying web server in public subnet on port 8080..."
sleep 4  # Explain what's being deployed
./deploy-server.sh demo-public 8080
sleep 6  # Wait for server to start

echo ""
echo "Testing web server response..."
sleep 3
sudo ip netns exec demo-public curl -s localhost:8080 | head -n 20
sleep 7  # Let them read HTML, explain it's working

# ========================================
# Part 4: VPC Isolation (1.5 minutes)
# ========================================
show_section "Part 4: VPC Isolation Demonstration"
sleep 3

echo "Creating a second VPC to test isolation..."
sleep 4  # Explain why second VPC
sudo ./vpcctl create-vpc vpc2 10.1.0.0/16
sleep 4  # Explain different CIDR

echo ""
echo "Adding subnet to second VPC..."
sleep 3
sudo ./vpcctl add-subnet vpc2 sub2 10.1.1.0/24 public
sleep 5  # Explain what was created

echo ""
echo "Testing isolation BEFORE peering..."
echo "Attempting to ping vpc2 (10.1.0.11) from demo VPC..."
echo "This should FAIL - demonstrating VPC isolation..."
sleep 5  # Explain what to expect
sudo ip netns exec demo-public ping -c 2 10.1.0.11 -W 2 || echo "✓ VPCs are properly isolated!"
sleep 7  # Explain why it failed (good thing!)

# ========================================
# Part 5: VPC Peering (1.5 minutes)
# ========================================
show_section "Part 5: VPC Peering Setup"
sleep 3

echo "Establishing peering connection between VPCs..."
echo "This will allow controlled communication..."
sleep 5  # Explain VPC peering concept
./setup-peering.sh demo vpc2 10.0.0.0/16 10.1.0.0/16 << ANSWER
y
ANSWER
sleep 6  # Let peering messages show, explain routes

echo ""
echo "Peering established. Now testing cross-VPC connectivity..."
sleep 4  # Explain what should happen now
sudo ip netns exec demo-public ping -c 3 10.1.0.11
sleep 7  # Explain that it works after peering

# ========================================
# Part 6: Security Groups (2 minutes)
# ========================================
show_section "Part 6: Security Groups (Firewall Rules)"
sleep 3

echo "Applying security policy to public subnet..."
echo "Policy allows HTTP (80, 8080) but BLOCKS SSH (22)..."
sleep 5  # Explain the policy rules
./apply-policy.sh policies/public-subnet-policy.json
sleep 6  # Wait for rules to apply

echo ""
echo "Viewing applied firewall rules..."
sleep 3
sudo ip netns exec demo-public iptables -L INPUT -n -v | head -n 18
sleep 8  # Explain the rules shown (DROP policy, ACCEPT rules, etc)

echo ""
echo "=========================================="
echo "Demonstrating Firewall Rule Enforcement"
echo "=========================================="
sleep 4

# Test 1: Allowed port
echo ""
echo "Test 1: Accessing ALLOWED port 8080..."
sleep 4  # Explain this should work
if sudo ip netns exec demo-public curl -s localhost:8080 --max-time 3 | grep -q "VPC"; then
    echo "✓ Success! Port 8080 is accessible (HTTP allowed by policy)"
else
    echo "✗ Failed (unexpected)"
fi
sleep 6  # Explain success

# Test 2: Blocked port
echo ""
echo "Test 2: Attempting to access BLOCKED port 22 (SSH)..."
sleep 4  # Explain this should fail

# Start test service on port 22
sudo ip netns exec demo-public python3 -m http.server 22 > /dev/null 2>&1 &
TEST_PID=$!
sleep 3

echo "Trying to connect to port 22..."
sleep 2
if sudo ip netns exec demo-public curl -s localhost:22 --max-time 3 > /dev/null 2>&1; then
    echo "✗ Port 22 is accessible (firewall not working)"
else
    echo "✓ Success! Port 22 is BLOCKED by firewall (SSH denied by policy)"
fi

# Clean up test service
kill $TEST_PID 2>/dev/null
sleep 6  # Explain firewall is working

echo ""
echo "Firewall enforcement demonstration complete!"
sleep 4

# ========================================
# Part 7: Cleanup (1 minute)
# ========================================
show_section "Part 7: Complete Resource Cleanup"
sleep 3

echo "Removing all VPC resources..."
sleep 4  # Explain what will be deleted
./cleanup-all.sh --force
./cleanup-all.sh --force
./cleanup-all.sh --force
./cleanup-all.sh --force
./cleanup-all.sh --force


# Wait for cleanup to complete
sleep 6

echo ""
echo "Verifying all resources removed..."
sleep 3
sudo ./vpcctl list
sleep 5  # Show empty list

# ========================================
# Conclusion (30 seconds)
# ========================================
show_section "Demo Complete - Summary"
sleep 3

echo "✓ Successfully demonstrated:"
echo "  • VPC and subnet creation"
echo "  • NAT gateway configuration"
echo "  • Inter-subnet routing"
echo "  • VPC isolation"
echo "  • VPC peering"
echo "  • Security group policies (allow + deny rules)"
echo "  • Web application deployment"
echo "  • Complete resource cleanup"
echo ""
sleep 8  # Time to summarize everything

echo "Project completed at: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""
echo "GitHub: https://github.com/Nicholasojinni/linux-vpc-implementation.git"
echo "Thank you for watching!"
echo ""
sleep 6
