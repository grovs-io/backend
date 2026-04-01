#!/usr/bin/env bash
set -e

# Colors for distinguishing output from each process
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

PIDS=()

cleanup() {
  echo ""
  echo "Shutting down all Sidekiq processes..."
  for pid in "${PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  wait
  echo "All Sidekiq processes stopped."
  exit 0
}

trap cleanup SIGINT SIGTERM

echo "Starting all Sidekiq processes..."
echo ""

bundle exec sidekiq -C config/sidekiq_worker.yml -c 20 2>&1 | sed "s/^/${GREEN}[worker]      ${NC}/" &
PIDS+=($!)

bundle exec sidekiq -C config/sidekiq_batch.yml -c 3 2>&1 | sed "s/^/${BLUE}[batch]       ${NC}/" &
PIDS+=($!)

bundle exec sidekiq -C config/sidekiq_scheduler.yml 2>&1 | sed "s/^/${YELLOW}[scheduler]   ${NC}/" &
PIDS+=($!)

bundle exec sidekiq -C config/sidekiq_device_updates.yml -c 3 2>&1 | sed "s/^/${MAGENTA}[dev_updates]  ${NC}/" &
PIDS+=($!)

bundle exec sidekiq -C config/sidekiq_maintenance.yml -c 3 2>&1 | sed "s/^/${RED}[maintenance]  ${NC}/" &
PIDS+=($!)

echo "All Sidekiq processes started. Press Ctrl+C to stop all."
echo ""

wait
