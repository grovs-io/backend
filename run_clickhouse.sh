#!/usr/bin/env bash
set -e

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CH_DIR="$SCRIPT_DIR/.clickhouse"
CONFIG="$CH_DIR/config.xml"

setup() {
  mkdir -p "$CH_DIR"/{data,tmp,user_files,format_schemas,logs}

  if [ ! -f "$CONFIG" ]; then
    cat > "$CONFIG" << 'EOF'
<clickhouse>
    <logger>
        <level>information</level>
        <log>./logs/clickhouse-server.log</log>
        <errorlog>./logs/clickhouse-server.err.log</errorlog>
    </logger>
    <path>./data/</path>
    <tmp_path>./tmp/</tmp_path>
    <user_files_path>./user_files/</user_files_path>
    <format_schema_path>./format_schemas/</format_schema_path>
    <listen_host>127.0.0.1</listen_host>
    <http_port>8123</http_port>
    <tcp_port>9000</tcp_port>
    <mysql_port>0</mysql_port>
    <interserver_http_port>0</interserver_http_port>
    <users>
        <default>
            <password></password>
            <networks>
                <ip>127.0.0.1</ip>
            </networks>
            <profile>default</profile>
            <quota>default</quota>
            <access_management>1</access_management>
        </default>
    </users>
    <profiles>
        <default/>
    </profiles>
    <quotas>
        <default/>
    </quotas>
</clickhouse>
EOF
    echo -e "${GREEN}Created ClickHouse config at $CONFIG${NC}"
  fi
}

cleanup() {
  echo ""
  echo "Shutting down ClickHouse..."
  kill "$CH_PID" 2>/dev/null || true
  wait "$CH_PID" 2>/dev/null || true
  echo "ClickHouse stopped."
  exit 0
}

# Check clickhouse is installed
if ! command -v clickhouse &>/dev/null; then
  echo -e "${RED}clickhouse not found. Install with: brew install clickhouse${NC}"
  exit 1
fi

setup

cd "$CH_DIR"
trap cleanup SIGINT SIGTERM

echo -e "${GREEN}Starting ClickHouse...${NC}"
echo "  Data dir: $CH_DIR/data"
echo "  HTTP:     http://127.0.0.1:8123"
echo "  TCP:      127.0.0.1:9000"
echo "  Logs:     $CH_DIR/logs/"
echo ""

clickhouse server --config-file="$CONFIG" 2>&1 | sed "s/^/${YELLOW}[clickhouse]  ${NC}/" &
CH_PID=$!

# Wait for it to be ready
for i in {1..30}; do
  if clickhouse client --query "SELECT 1" &>/dev/null 2>&1; then
    echo -e "${GREEN}ClickHouse is ready ($(clickhouse client --query "SELECT version()"))${NC}"
    echo ""

    # Create dev database if needed
    clickhouse client --query "CREATE DATABASE IF NOT EXISTS grovs_development"
    echo "Database grovs_development ensured."

    # Run schema setup if tables don't exist
    TABLE_COUNT=$(clickhouse client --query "SELECT count() FROM system.tables WHERE database = 'grovs_development'" 2>/dev/null)
    if [ "$TABLE_COUNT" = "0" ]; then
      echo "No tables found — running schema setup..."
      cd "$SCRIPT_DIR"
      bundle exec rake clickhouse:setup 2>&1 | grep -v "^D,\|^\[dotenv\]\|^W,"
      cd "$CH_DIR"
    else
      echo "$TABLE_COUNT tables in grovs_development."
    fi

    echo ""
    echo -e "${GREEN}Press Ctrl+C to stop.${NC}"
    break
  fi
  sleep 1
done

wait "$CH_PID"
