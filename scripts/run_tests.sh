#!/bin/bash
# Run ErlCracker Common Test suite

set -e

echo "================================================"
echo "ErlCracker Test Suite"
echo "================================================"
echo ""

# Clean previous test artifacts
echo "Cleaning previous test artifacts..."
rm -rf _build/test/logs/*

# Compile
echo "Compiling..."
rebar3 compile

# Run Common Test
echo ""
echo "Running Common Test suite..."
echo ""
rebar3 ct --verbose

# Show results
echo ""
echo "================================================"
echo "Test Results"
echo "================================================"

# Check if tests passed
if [ $? -eq 0 ]; then
    echo "✓ All tests passed!"
    echo ""
    echo "View detailed results:"
    echo "  _build/test/logs/index.html"
    exit 0
else
    echo "✗ Tests failed!"
    echo ""
    echo "View detailed results:"
    echo "  _build/test/logs/index.html"
    exit 1
fi
