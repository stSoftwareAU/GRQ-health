#!/bin/bash

# Test Server Starter Script for GRQ Validation Dashboard
# 
# This script provides an easy way to start the test server
# 
# Usage:
#   ./tests/start-server.sh [port]
# 
# Default port is 8000 if not specified.

set -e

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Change to project root directory
cd "$PROJECT_ROOT"

# Check if Deno is installed
if ! command -v deno &> /dev/null; then
    echo "❌ Error: Deno is not installed or not in PATH"
    echo "Please install Deno from https://deno.land/"
    exit 1
fi

# Get port from command line arguments or use default
PORT=${1:-8000}

echo "🚀 Starting GRQ Validation Dashboard Test Server"
echo "📁 Project root: $PROJECT_ROOT"
echo "🌐 Server will be available at: http://localhost:$PORT"
echo "⏹️  Press Ctrl+C to stop the server"
echo ""

# Start the server using Deno
deno run --allow-net --allow-read "$SCRIPT_DIR/server.ts" "$PORT" 