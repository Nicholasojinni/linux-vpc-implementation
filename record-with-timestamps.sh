#!/bin/bash

# Function to show timestamped section headers
show_section() {
    echo ""
    echo "=========================================="
    echo "$(date '+%H:%M:%S') - $1"
    echo "=========================================="
    echo ""
    sleep 2
}

# Clean start
cd ~/vpc-project
./cleanup-all.sh --force
clear

# ========================================
# Introduction
# ========================================
show_section "Introduction: Linux VPC Implementation"
echo "Project: Building Virtual Private Cloud from Scratch"
echo "Author: Nicholas Ojinni"
echo ""
pwd
ls -la
sleep 3

show_section "CLI Tool Overview"
./vpcctl help
sleep 3

# ========================================
# Part 1: VPC Creation
# ========================================
show_section "Part 1: Creating VPC with Subnets"

echo "Creating VPC 'demo' with CIDR 10.0.0.0/16..."
sudo ./vpcctl create-vpc demo 10.0.0.0/16
sleep 2

echo "Adding public subnet..."
sudo ./vpcctl add-subnet demo public 10.0.1.0/24 public
sleep 2

echo "Adding private subnet..."
sudo ./vpcctl add-subnet demo private 10.0.2.0/24 private
sleep 2

echo "Listing VPCs..."
sudo ./vpcctl list
sleep 3

# ========================================
# Part 2: NAT & Connectivity
# ========================================
show_section "Part 2: NAT Gateway & Connectivity Tests"

echo "Setting up NAT gateway..."
sudo ./vpcctl setup-nat demo enp0s3
sleep 2

echo "Test 1: Ping bridge gateway (10.0.0.1)..."
sudo ip netns exec demo-public ping -c 3 10.0.0.1
sleep 2

echo "Test 2: Ping between subnets (public → private)..."
sudo ip netns exec demo-public ping -c 3 10.0.0.12
sleep 2

echo "Test 3: Internet access via NAT (ping 8.8.8.8)..."
sudo ip netns exec demo-public ping -c 3 8.8.8.8
sleep 3

# ========================================
# Part 3: Application Deployment
# ========================================
show_section "Part 3: Deploying Web Application"

echo "Deploying web server in public subnet (port 8080)..."
./deploy-server.sh demo-public 8080
sleep 3

echo "Testing web server from within namespace..."
sudo ip netns exec demo-public curl -s localhost:8080 | head -n 15
sleep 3

# ========================================
# Part 4: VPC Isolation
# ========================================
show_section "Part 4: Testing VPC Isolation"

echo "Creating second VPC (vpc2)..."
sudo ./vpcctl create-vpc vpc2 10.1.0.0/16
sudo ./vpcctl add-subnet vpc2 sub2 10.1.1.0/24 public
sleep 2

echo "Testing isolation BEFORE peering (should FAIL)..."
echo "Attempting to ping vpc2 from demo VPC..."
sudo ip netns exec demo-public ping -c 2 10.1.0.11 -W 2 || echo "✓ VPCs are properly isolated!"
sleep 3

# ========================================
# Part 5: VPC Peering
# ========================================
show_section "Part 5: Setting up VPC Peering"

echo "Establishing peering connection between demo and vpc2..."
./setup-peering.sh demo vpc2 10.0.0.0/16 10.1.0.0/16 << ANSWER
y
ANSWER
sleep 3

echo "Testing cross-VPC connectivity AFTER peering..."
sudo ip netns exec demo-public ping -c 3 10.1.0.11
sleep 3

# ========================================
# Part 6: Security Groups
# ========================================
show_section "Part 6: Applying Security Policies"

echo "Applying firewall rules to public subnet..."
./apply-policy.sh policies/public-subnet-policy.json
sleep 2

echo "Viewing applied iptables rules..."
sudo ip netns exec demo-public iptables -L INPUT -n -v | head -n 15
sleep 3

# ========================================
# Part 7: Cleanup
# ========================================
show_section "Part 7: Resource Cleanup"

echo "Removing all VPC resources..."
./cleanup-all.sh --force
sleep 2

echo "Verifying cleanup (should show no VPCs)..."
sudo ./vpcctl list
sleep 2

# ========================================
# Conclusion
# ========================================
show_section "Demo Complete"
echo "✓ All VPC features demonstrated successfully"
echo ""
echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
echo "Duration: ~5 minutes"
echo ""
echo "GitHub: https://github.com/Nicholasojinni/linux-vpc-implementation.git"
echo "Thank you for watching!"
echo ""

