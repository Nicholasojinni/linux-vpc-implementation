#!/bin/bash
# Complete VPC Demo Script

# IMPORTANT: Change this to YOUR internet interface
INTERNET_IF="enp0s3"

echo "=== Starting Complete VPC Demo ==="
echo ""

# Step 1: Create first VPC
echo "Step 1: Creating VPC 'myvpc'..."
sudo ./vpcctl create-vpc myvpc 10.0.0.0/16
sleep 1

# Step 2: Add public subnet
echo ""
echo "Step 2: Adding public subnet..."
sudo ./vpcctl add-subnet myvpc public-subnet 10.0.1.0/24 public
sleep 1

# Step 3: Add private subnet
echo ""
echo "Step 3: Adding private subnet..."
sudo ./vpcctl add-subnet myvpc private-subnet 10.0.2.0/24 private
sleep 1

# Step 4: List VPCs
echo ""
echo "Step 4: Listing VPCs..."
sudo ./vpcctl list

# Step 5: Setup NAT
echo ""
echo "Step 5: Setting up NAT gateway..."
sudo ./vpcctl setup-nat myvpc $INTERNET_IF
sleep 1

# Step 6: Test connectivity
echo ""
echo "Step 6: Testing connectivity..."
echo "  - Ping between subnets..."
sudo ip netns exec myvpc-public-subnet ping -c 3 10.0.0.12

echo "  - Ping internet from public subnet..."
sudo ip netns exec myvpc-public-subnet ping -c 3 8.8.8.8

# Step 7: Deploy web servers
echo ""
echo "Step 7: Deploying web servers..."
./deploy-server.sh myvpc-public-subnet 8080
./deploy-server.sh myvpc-private-subnet 8081
sleep 2

# Step 8: Test web servers
echo ""
echo "Step 8: Testing web servers..."
echo "  - Public subnet server..."
sudo ip netns exec myvpc-public-subnet curl -s http://localhost:8080 | head -n 10

echo "  - Access private server from public subnet..."
sudo ip netns exec myvpc-public-subnet curl -s http://10.0.0.12:8081 | head -n 10

# Step 9: Apply security policy
echo ""
echo "Step 9: Applying security policies..."
./apply-policy.sh policies/public-subnet-policy.json

# Step 10: Create second VPC for isolation test
echo ""
echo "Step 10: Creating second VPC to test isolation..."
sudo ./vpcctl create-vpc vpc2 10.1.0.0/16
sudo ./vpcctl add-subnet vpc2 public-subnet2 10.1.1.0/24 public
sleep 1

# Step 11: Test VPC isolation
echo ""
echo "Step 11: Testing VPC isolation (should fail)..."
sudo ip netns exec myvpc-public-subnet ping -c 2 10.1.0.11 -W 3 || echo "✓ VPCs are properly isolated!"

# Step 12: Setup VPC peering
echo ""
echo "Step 12: Setting up VPC peering..."
./setup-peering.sh myvpc vpc2 10.0.0.0/16 10.1.0.0/16 << EOF
y
EOF
sleep 2

# Step 13: Test cross-VPC connectivity
echo ""
echo "Step 13: Testing cross-VPC connectivity after peering..."
sudo ip netns exec myvpc-public-subnet ping -c 3 10.1.0.11

echo ""
echo "=== Demo Complete! ==="
echo ""
echo "Your VPCs are running. To see everything:"
echo "  sudo ./vpcctl list"
echo ""
echo "To run automated tests:"
echo "  ./run-tests.sh"
echo ""
echo "To clean up everything:"
echo "  ./cleanup-all.sh"
