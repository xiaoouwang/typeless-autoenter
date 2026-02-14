#!/bin/bash
PID_FILE="/tmp/typeless-autoenter.pid"

if [ ! -f "$PID_FILE" ]; then
    echo "typeless-autoenter is not running"
    exit 1
fi

PID=$(cat "$PID_FILE")

if ! kill -0 "$PID" 2>/dev/null; then
    echo "typeless-autoenter (pid $PID) is not running"
    rm -f "$PID_FILE"
    exit 1
fi

kill -SIGUSR1 "$PID"
echo "toggled (sent SIGUSR1 to pid $PID)"
