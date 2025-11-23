#!/bin/bash
# Build Go binaries for erlcracker

set -e

echo "Building Go test module..."
mkdir -p priv/bin
cd priv/go
go build -o ../bin/test_module .
cd ../..
echo "Go binary built successfully: priv/bin/test_module"
