#!/system/bin/sh
DATA_DIR="/data/adb/uclamp_profiler"
PID_FILE="${DATA_DIR}/daemon.pid"

if [ -f "$PID_FILE" ]; then
    pid=$(cat "$PID_FILE" 2>/dev/null)
    [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null
fi

# Clean up Toast Popup helper APK
pm uninstall bellavita.toast >/dev/null 2>&1

rm -rf "$DATA_DIR"
