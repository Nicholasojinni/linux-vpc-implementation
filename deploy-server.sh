#!/bin/bash
#
# deploy-server.sh - Deploy web server in network namespace
# TESTED AND WORKING VERSION
#

if [ $# -lt 1 ]; then
    echo "Usage: $0 <namespace> [port]"
    echo "Example: $0 demo-public 8080"
    exit 1
fi

NAMESPACE=$1
PORT=${2:-8080}

# Check if namespace exists
if ! sudo ip netns list | grep -q "^${NAMESPACE}"; then
    echo "ERROR: Namespace '$NAMESPACE' does not exist"
    exit 1
fi

echo "Deploying web server in $NAMESPACE on port $PORT..."

# Create HTML content
HTML='<!DOCTYPE html>
<html>
<head>
    <title>VPC Test Server</title>
    <style>
        body { 
            font-family: Arial; 
            max-width: 600px; 
            margin: 50px auto; 
            padding: 20px;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
        }
        .box { 
            background: rgba(255,255,255,0.1); 
            padding: 30px; 
            border-radius: 10px; 
        }
    </style>
</head>
<body>
    <div class="box">
        <h1>✓ VPC Test Server</h1>
        <p><strong>Namespace:</strong> '"$NAMESPACE"'</p>
        <p><strong>Port:</strong> '"$PORT"'</p>
        <p><strong>Status:</strong> Running</p>
    </div>
</body>
</html>'

# Create directory and HTML file inside namespace
WEBDIR="/tmp/web_${PORT}"
sudo ip netns exec "$NAMESPACE" bash -c "mkdir -p $WEBDIR && echo '$HTML' > $WEBDIR/index.html"

# Start web server in background (THE KEY FIX!)
sudo ip netns exec "$NAMESPACE" bash -c "cd $WEBDIR && setsid python3 -m http.server $PORT >/dev/null 2>&1 &"

# Wait for server to start
sleep 2

# Check if server is running (using ss command which is available)
if sudo ip netns exec "$NAMESPACE" ss -tuln | grep -q ":${PORT}"; then
    echo "✓ Server started successfully!"
    echo "  Namespace: $NAMESPACE"
    echo "  Port: $PORT"
    echo ""
    echo "Test with: sudo ip netns exec $NAMESPACE curl localhost:$PORT"
    exit 0
else
    echo "✗ Server failed to start"
    exit 1
fi
