#!/system/bin/sh
# ==============================================================================
# Autonomous Profiler Daemon for Sony Xperia SDM845 (KernelSU Next)
# Monitors active foreground package, power state, and adjusts profiles
# ==============================================================================

MODDIR="/data/adb/modules/uclamp_auto_profiler"
DATA_DIR="/data/adb/uclamp_profiler"
CONFIG_FILE="${DATA_DIR}/config.json"
GAME_APPS_FILE="${DATA_DIR}/game_apps.txt"
BATTERY_APPS_FILE="${DATA_DIR}/battery_apps.txt"
PID_FILE="${DATA_DIR}/daemon.pid"
LOG_FILE="${DATA_DIR}/daemon.log"
FORCED_MODE_FILE="${DATA_DIR}/forced_mode"
CURRENT_MODE_FILE="${DATA_DIR}/current_mode"

TUNER="${MODDIR}/tuner.sh"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [daemon] $*" >> "$LOG_FILE"
}

# 1. PID & Singleton Check
if [ -f "$PID_FILE" ]; then
    old_pid=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$old_pid" ] && [ -d "/proc/$old_pid" ]; then
        kill -9 "$old_pid" 2>/dev/null
    fi
fi
echo $$ > "$PID_FILE"
log "Daemon started with PID $$"

# 2. Config & Default Lists Setup
mkdir -p "$DATA_DIR"
if [ ! -f "$CONFIG_FILE" ]; then
    cp "${MODDIR}/default_config.json" "$CONFIG_FILE"
fi

# Populate game_apps.txt if missing
if [ ! -f "$GAME_APPS_FILE" ]; then
    sh "$TUNER" sync_config
fi

# Initial state
current_mode="balance"
echo "$current_mode" > "$CURRENT_MODE_FILE"
sh "$TUNER" balance

last_pkg=""
last_wake=""

while true; do
    # Check if forced mode is set
    forced="auto"
    [ -f "$FORCED_MODE_FILE" ] && forced=$(cat "$FORCED_MODE_FILE" 2>/dev/null | tr -d ' \n\r')

    # Detect current foreground package
    pkg=$(dumpsys window displays 2>/dev/null | grep 'mFocusedApp' | head -n 1 | sed -E 's/.* u[0-9]+ ([^/]+)\/.*/\1/')
    [ -z "$pkg" ] && pkg="com.android.launcher"

    # Detect wakefulness
    wake=$(dumpsys power 2>/dev/null | grep -i 'mWakefulness=' | head -n 1 | cut -d'=' -f2 | tr -d ' \n\r')
    [ -z "$wake" ] && wake="Awake"

    target_mode="balance"

    if [ "$forced" = "game" ]; then
        target_mode="game"
    elif [ "$forced" = "battery" ]; then
        target_mode="battery"
    elif [ "$forced" = "balance" ]; then
        target_mode="balance"
    else
        # AUTO PROFILING DECISION LOGIC
        if [ "$wake" != "Awake" ]; then
            # Device screen is off/sleeping
            target_mode="battery"
        elif [ -f "$GAME_APPS_FILE" ] && grep -q -F -x "$pkg" "$GAME_APPS_FILE" 2>/dev/null; then
            # App is designated as Game
            target_mode="game"
        elif [ -f "$BATTERY_APPS_FILE" ] && grep -q -F -x "$pkg" "$BATTERY_APPS_FILE" 2>/dev/null; then
            # App is designated as Battery Saver
            target_mode="battery"
        else
            # Default Daily Balanced
            target_mode="balance"
        fi
    fi

    # Mode switch trigger
    if [ "$target_mode" != "$current_mode" ]; then
        log "Switching mode: $current_mode -> $target_mode (app: $pkg, wake: $wake)"
        if [ "$target_mode" = "game" ]; then
            sh "$TUNER" game "$pkg"
        elif [ "$target_mode" = "battery" ]; then
            sh "$TUNER" battery "$pkg"
        else
            sh "$TUNER" balance "$pkg"
        fi
        current_mode="$target_mode"
        echo "$current_mode" > "$CURRENT_MODE_FILE"
    elif [ "$current_mode" = "game" ]; then
        # Continuous game process protection while gaming
        for pid in $(pidof "$pkg" 2>/dev/null); do
            if [ -d "/proc/$pid" ]; then
                cur_adj=$(cat "/proc/$pid/oom_score_adj" 2>/dev/null)
                if [ "$cur_adj" != "-1000" ]; then
                    chmod 666 "/proc/$pid/oom_score_adj" 2>/dev/null
                    echo -1000 > "/proc/$pid/oom_score_adj" 2>/dev/null
                    echo -17 > "/proc/$pid/oom_adj" 2>/dev/null
                    chmod 444 "/proc/$pid/oom_score_adj" 2>/dev/null
                    echo "$pid" > /dev/cpuset/top-app/tasks 2>/dev/null
                    renice -n -20 -p "$pid" 2>/dev/null
                fi
            fi
        done

        # Ensure bypass charging is active if plugged in while gaming
        local bypass_cfg=true
        if [ -f "$CONFIG_FILE" ]; then
            if grep -q '"game_bypass_charging": false' "$CONFIG_FILE" 2>/dev/null; then
                bypass_cfg=false
            fi
        fi
        if [ "$bypass_cfg" = "true" ]; then
            local usb_v=$(cat /sys/class/power_supply/usb/voltage_now 2>/dev/null || echo 0)
            local cur_suspend=$(cat /sys/class/power_supply/battery/input_suspend 2>/dev/null || echo 0)
            if [ "$usb_v" -gt 4000000 ] && [ "$cur_suspend" != "1" ]; then
                sh "$TUNER" set_bypass 1
            fi
        fi
    fi

    last_pkg="$pkg"
    last_wake="$wake"

    sleep 2
done
