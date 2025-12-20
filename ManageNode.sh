 
#!/bin/bash
# ManageNode.sh - manage Subtensor node (lite -> promote to full, full, archive)
# Usage:
#   ./ManageNode.sh {start|stop|status|restart|purge|view_logs|purge_logs}
# Or run with no args for interactive prompt.
#
# Node name is always "subtensor-node" regardless of mode.

set -euo pipefail

# === CONFIG ===
NODE_DIR="$HOME/subtensor"
NODE_BIN="$NODE_DIR/target/release/node-subtensor"
LOG_FILE="$NODE_DIR/subtensor.log"
PID_FILE="$NODE_DIR/subtensor.pid"
MODE_FILE="$NODE_DIR/last_mode.txt"
DB_PATH="$NODE_DIR/data/chains/bittensor/db/full"
NODE_NAME="subtensor-node"
CPU_CORES="0-5"    # used for all starts (taskset)
DEFAULT_BLOCKS=7200

# Base command; keep as you had it (quoted expansions will be used later)
BASE_COMMAND="$NODE_BIN --database rocksdb --offchain-worker always --prometheus-external --base-path $HOME/subtensor/data --chain chainspecs/raw_spec_finney.json --no-mdns --bootnodes /dns/bootnode.finney.chain.opentensor.ai/tcp/30333/ws/p2p/12D3KooWRwbMb85RWnT8DSXSYMWQtuDwh4LJzndoRrTDotTR5gDC --experimental-rpc-endpoint listen-addr=10.2.1.103:9944"

# === Helpers ===
log() { echo "[$(date +'%F %T')] $*"; }

prompt_action() {
    if [ -z "${ACTION:-}" ]; then
        echo "What action do you want to perform? {start|stop|status|restart|purge|view_logs|purge_logs}"
        read -r ACTION
    fi
}

get_last_mode() {
    if [ -f "$MODE_FILE" ]; then
        cat "$MODE_FILE"
    else
        echo "unknown"
    fi
}

prompt_mode() {
    LAST_MODE="$(get_last_mode)"
    while true; do
        echo "What mode do you want the node to run in? (lite/full/archive)"
        read -r MODE
        case "$MODE" in
            lite)
                # Use promote so node auto-converts to full once warp sync completes
                SYNC_FLAGS="--sync warp"
                # Ask how many blocks to keep once promoted (so pruning is applied after promotion)
                echo "How many blocks to retain after promotion to full? (default $DEFAULT_BLOCKS)"
                read -r BLOCKS
                if [ -z "$BLOCKS" ]; then BLOCKS=$DEFAULT_BLOCKS; fi
                PRUNING_FLAGS="--pruning $BLOCKS"
                if [ "$LAST_MODE" = "archive" ]; then
                    echo "Warning: Switching from archive to lite/full often requires DB purge. If you see errors, run 'purge'."
                fi
                break
                ;;
            full)
                SYNC_FLAGS="--sync full"
                echo "How many blocks do you want to retain? (default $DEFAULT_BLOCKS)"
                read -r BLOCKS
                if [ -z "$BLOCKS" ]; then BLOCKS=$DEFAULT_BLOCKS; fi
                PRUNING_FLAGS="--pruning $BLOCKS"
                if [ "$LAST_MODE" = "archive" ]; then
                    echo "Warning: Switching from archive to pruned full often requires DB purge. If you see DB incompatibility, run 'purge'."
                fi
                break
                ;;
            archive)
                SYNC_FLAGS="--sync full"
                PRUNING_FLAGS="--pruning archive"
                echo "Warning: Archive requires a fresh DB and large disk (~2TB+). If you previously ran lite/full, you should purge the DB first."
                break
                ;;
            *)
                echo "Invalid input. Please enter 'lite', 'full', or 'archive'."
                ;;
        esac
    done
}

# === ACTIONS ===
start() {
    if [ -f "$PID_FILE" ]; then
        PID=$(cat "$PID_FILE")
        if ps -p "$PID" > /dev/null 2>&1; then
            log "Node already appears to be running (PID: $PID)."
            return 0
        else
            log "Removing stale PID file."
            rm -f "$PID_FILE"
        fi
    fi

    prompt_mode

    # Construct final command
    NODE_COMMAND="$BASE_COMMAND $SYNC_FLAGS $PRUNING_FLAGS --name $NODE_NAME"

    log "Starting Subtensor node in mode: $MODE"
    log "Node command: $NODE_COMMAND"

    cd "$NODE_DIR" || { log "Cannot cd to $NODE_DIR"; return 1; }

    # Always start with taskset for CPU pinning
    nohup bash -c "taskset -c $CPU_CORES $NODE_COMMAND" >> "$LOG_FILE" 2>&1 &

    PID=$!
    echo "$PID" > "$PID_FILE"

    # brief check
    sleep 5
    if ps -p "$PID" > /dev/null 2>&1; then
        echo "$MODE" > "$MODE_FILE"
        log "Node started with PID $PID (pinned to cores $CPU_CORES). Logs: $LOG_FILE"
    else
        rm -f "$PID_FILE"
        log "Node failed to start. Check $LOG_FILE for errors. If you changed mode from archive, DB may be incompatible - consider running 'purge'."
        return 1
    fi
}

stop() {
    if [ ! -f "$PID_FILE" ]; then
        log "Node not running (no PID file)."
        return 0
    fi
    PID=$(cat "$PID_FILE")
    if ! ps -p "$PID" > /dev/null 2>&1; then
        log "Stale PID file found; removing."
        rm -f "$PID_FILE"
        return 0
    fi
    log "Stopping Subtensor node (PID: $PID)..."
    kill -TERM "$PID" || kill -9 "$PID"
    # Wait up to 10 seconds for exit
    for i in {1..10}; do
        if ! ps -p "$PID" > /dev/null 2>&1; then
            break
        fi
        sleep 1
    done
    if ps -p "$PID" > /dev/null 2>&1; then
        log "PID did not exit cleanly; sending KILL."
        kill -9 "$PID" || true
    fi
    rm -f "$PID_FILE"
    log "Node stopped."
}

status() {
    if [ -f "$PID_FILE" ]; then
        PID=$(cat "$PID_FILE")
        if ps -p "$PID" > /dev/null 2>&1; then
            echo "Node running (PID: $PID). Mode: $(get_last_mode)"
            echo "Log tail (last 10 lines):"
            tail -n 10 "$LOG_FILE" 2>/dev/null || true
        else
            echo "Stale PID file; node not running. Removing PID file."
            rm -f "$PID_FILE"
        fi
    else
        echo "Node is not running. Last mode: $(get_last_mode)"
    fi
}

purge() {
    if [ -f "$PID_FILE" ]; then
        echo "Stop the node first with 'stop' before purging." && return 1
    fi
    echo "Are you sure you want to delete the database at $DB_PATH? This requires a full resync and can take a long time. (y/n)"
    read -r CONFIRM
    if [ "$CONFIRM" = "y" ]; then
        log "Purging DB at $DB_PATH..."
        rm -rf "$DB_PATH"
        rm -f "$MODE_FILE"
        log "Database purged. Start the node in desired mode now."
    else
        log "Purge cancelled."
    fi
}

view_logs() {
    if [ ! -f "$LOG_FILE" ]; then
        log "Log file does not exist: $LOG_FILE"
        return 1
    fi
    echo "How many lines do you want to view? (default 100)"
    read -r ROWS
    if [ -z "$ROWS" ] || ! [[ "$ROWS" =~ ^[0-9]+$ ]]; then
        ROWS=100
    fi
    echo "---- Last $ROWS lines from $LOG_FILE ----"
    tail -n "$ROWS" "$LOG_FILE"
    echo "---- end logs ----"
}

purge_logs() {
    if [ ! -f "$LOG_FILE" ]; then
        log "Log file does not exist: $LOG_FILE"
        return 1
    fi
    echo "Are you sure you want to clear the log file at $LOG_FILE? (y/n)"
    read -r CONFIRM
    if [ "$CONFIRM" = "y" ]; then
        : > "$LOG_FILE"
        log "Log file purged."
    else
        log "Log purge cancelled."
    fi
}

# === MAIN ===
ACTION="${1:-}"
prompt_action

case "$ACTION" in
    start)
        start
        ;;
    stop)
        stop
        ;;
    status)
        status
        ;;
    restart)
        stop
        start
        ;;
    purge)
        purge
        ;;
    view_logs)
        view_logs
        ;;
    purge_logs)
        purge_logs
        ;;
    *)
        echo "Usage: $0 {start|stop|status|restart|purge|view_logs|purge_logs}"
        exit 1
        ;;
esac
