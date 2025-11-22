#!/bin/bash
# Watch application logs with colorized output

set -e

cd "$(dirname "$0")/.."

echo "Starting log watcher..."
echo ""
echo "Options:"
echo "  --all, -a        Show all existing logs first"
echo "  --no-follow, -n  Don't follow new logs (just show and exit)"
echo ""

python3 tools/watch_logs.py "$@"
