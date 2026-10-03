#!/system/bin/sh
# ==============================================================================
# UCLAMP & Hardware Profiler Engine for Sony Xperia SDM845 (Tama)
# Tailored for CASS + UCLAMP + Adreno 630 + Anxiety I/O + le9
# ==============================================================================

MODDIR="${MODDIR:-/data/adb/modules/uclamp_auto_profiler}"
[ -f "${0%/*}/bin/fas_governor" ] && MODDIR="${0%/*}"
DATA_DIR="/data/adb/uclamp_profiler"
CONFIG_FILE="${DATA_DIR}/config.json"
STATE_FILE="${DATA_DIR}/state.json"
GAME_APPS_FILE="${DATA_DIR}/game_apps.txt"
BATTERY_APPS_FILE="${DATA_DIR}/battery_apps.txt"
PID_FILE="${DATA_DIR}/daemon.pid"
LOG_FILE="${DATA_DIR}/daemon.log"

CPUSET="/dev/cpuset"
SYS_CPU="/sys/devices/system/cpu"
SYS_GPU="/sys/class/kgsl/kgsl-3d0"
SYS_SDA="/sys/block/sda"
SYS_ZRAM="/sys/block/zram0"

mkdir -p "$DATA_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

set_uclamp() {
    local grp="$1" min="$2" max="$3" boost="$4" ls="$5"
    local p="${CPUSET}/${grp}"
    if [ -d "$p" ]; then
        [ -f "${p}/uclamp.max" ] && echo "$max" > "${p}/uclamp.max" 2>/dev/null
        [ -f "${p}/uclamp.min" ] && echo "$min" > "${p}/uclamp.min" 2>/dev/null
        [ -f "${p}/uclamp.boosted" ] && echo "$boost" > "${p}/uclamp.boosted" 2>/dev/null
        [ -f "${p}/uclamp.latency_sensitive" ] && echo "$ls" > "${p}/uclamp.latency_sensitive" 2>/dev/null
    fi
}

setup_zram() {
    local target_mb="${1:-4096}"
    local current_mb=$(awk '{print int($1/1048576)}' "${SYS_ZRAM}/disksize" 2>/dev/null || echo 0)
    local current_alg=$(grep -o '\[[a-z0-9]*\]' "${SYS_ZRAM}/comp_algorithm" 2>/dev/null | tr -d '[]')

    # If swap is active and sized >= target_mb - 256MB and using zstd, skip
    if [ "$current_mb" -ge "$((target_mb - 256))" ] && [ "$current_alg" = "zstd" ] && grep -q "zram0" /proc/swaps 2>/dev/null; then
        return 0
    fi

    if [ "$current_mb" -lt "$((target_mb - 256))" ] || [ "$current_alg" != "zstd" ]; then
        swapoff /dev/block/zram0 2>/dev/null
        echo 1 > "${SYS_ZRAM}/reset" 2>/dev/null
        if grep -q "zstd" "${SYS_ZRAM}/comp_algorithm" 2>/dev/null; then
            echo zstd > "${SYS_ZRAM}/comp_algorithm" 2>/dev/null
        else
            echo lz4 > "${SYS_ZRAM}/comp_algorithm" 2>/dev/null
        fi
        echo "${target_mb}M" > "${SYS_ZRAM}/disksize" 2>/dev/null
        mkswap /dev/block/zram0 >/dev/null 2>&1
        swapon /dev/block/zram0 -p 32767 >/dev/null 2>&1
    elif ! grep -q "zram0" /proc/swaps 2>/dev/null; then
        mkswap /dev/block/zram0 >/dev/null 2>&1
        swapon /dev/block/zram0 -p 32767 >/dev/null 2>&1
    fi
}

protect_game() {
    local target_pkg="$1"
    [ -z "$target_pkg" ] && return
    for pid in $(pidof "$target_pkg" 2>/dev/null); do
        if [ -d "/proc/$pid" ]; then
            chmod 666 "/proc/$pid/oom_score_adj" 2>/dev/null
            echo -1000 > "/proc/$pid/oom_score_adj" 2>/dev/null
            echo -17 > "/proc/$pid/oom_adj" 2>/dev/null
            chmod 444 "/proc/$pid/oom_score_adj" 2>/dev/null
            echo "$pid" > "${CPUSET}/top-app/tasks" 2>/dev/null
            renice -n -20 -p "$pid" 2>/dev/null
        fi
    done
}

set_bypass() {
    local enable="$1"
    local node="/sys/class/power_supply/battery/input_suspend"
    [ ! -e "$node" ] && return 1

    if [ "$enable" = "1" ] || [ "$enable" = "true" ] || [ "$enable" = "on" ]; then
        # Check if USB power is connected
        local usb_v=$(cat /sys/class/power_supply/usb/voltage_now 2>/dev/null || echo 0)
        local usb_online=$(cat /sys/class/power_supply/usb/online 2>/dev/null || echo 0)
        local pc_online=$(cat /sys/class/power_supply/pc_port/online 2>/dev/null || echo 0)
        local bat_st=$(cat /sys/class/power_supply/battery/status 2>/dev/null || echo "")

        if [ "$usb_v" -gt 4000000 ] || [ "$usb_online" = "1" ] || [ "$pc_online" = "1" ] || [ "$bat_st" = "Charging" ] || [ "$bat_st" = "Full" ] || [ "$bat_st" = "Not charging" ]; then
            echo 1 > "$node" 2>/dev/null
            log "Game Bypass Charging ACTIVATED (hardware input_suspend = 1)"
        fi
    else
        echo 0 > "$node" 2>/dev/null
        log "Game Bypass Charging DEACTIVATED (hardware input_suspend = 0)"
    fi
}

stop_thermal_engine() {
    stop thermal-engine >/dev/null 2>&1
    log "Thermal Throttling DISABLED (thermal-engine stopped)"
}

start_thermal_engine() {
    start thermal-engine >/dev/null 2>&1
    log "Thermal Throttling ENABLED (thermal-engine started)"
}

set_thermal() {
    local enable="$1"
    case "$enable" in
        0|off|disable)
            stop_thermal_engine
            echo "Thermal Throttling: DISABLED"
            if [ -f "$CONFIG_FILE" ]; then
                if grep -q '"disable_thermal_throttling"' "$CONFIG_FILE" 2>/dev/null; then
                    sed -i 's/"disable_thermal_throttling": *[a-z]*/"disable_thermal_throttling": true/' "$CONFIG_FILE" 2>/dev/null
                fi
            fi
            ;;
        1|on|enable)
            start_thermal_engine
            echo "Thermal Throttling: ENABLED"
            if [ -f "$CONFIG_FILE" ]; then
                if grep -q '"disable_thermal_throttling"' "$CONFIG_FILE" 2>/dev/null; then
                    sed -i 's/"disable_thermal_throttling": *[a-z]*/"disable_thermal_throttling": false/' "$CONFIG_FILE" 2>/dev/null
                fi
            fi
            ;;
        status)
            local st=$(getprop init.svc.thermal-engine 2>/dev/null || echo "unknown")
            local pid=$(pidof thermal-engine 2>/dev/null || echo "")
            if [ "$st" = "running" ] || [ -n "$pid" ]; then
                echo "Thermal Throttling: ENABLED (thermal-engine running, PID: ${pid:-?})"
            else
                echo "Thermal Throttling: DISABLED (thermal-engine stopped)"
            fi
            ;;
        *)
            echo "Usage: uclamp thermal [on|off|status]"
            ;;
    esac
}

start_fas() {
    local pkg="$1"
    local fps="${2}"
    [ ! -c "/dev/encore_fas" ] && return 0
    [ ! -x "${MODDIR}/bin/fas_governor" ] && return 0
    [ -z "$pkg" ] && return 0

    # Read target FPS from config if not provided
    if [ -z "$fps" ] && [ -f "$CONFIG_FILE" ]; then
        local cfg_fps=$(grep '"fas_target_fps":' "$CONFIG_FILE" 2>/dev/null | awk '{print $2}' | tr -d ',')
        [ -n "$cfg_fps" ] && fps="$cfg_fps"
    fi
    [ -z "$fps" ] && fps=0

    local target_pid=$(pidof "$pkg" 2>/dev/null | awk '{print $1}')
    if [ -z "$target_pid" ]; then
        log "Encore FAS: Process for $pkg not running yet, waiting for daemon attach"
        return 0
    fi

    if [ -f "${DATA_DIR}/fas_governor.pid" ]; then
        local cur_fpid=$(cat "${DATA_DIR}/fas_governor.pid" 2>/dev/null)
        if [ -n "$cur_fpid" ] && [ -d "/proc/$cur_fpid" ]; then
            local cur_attached=$(grep '"pid":' "${DATA_DIR}/fas_state.json" 2>/dev/null | awk '{print $2}' | tr -d ',')
            if [ "$cur_attached" = "$target_pid" ]; then
                log "Encore FAS already running on PID $target_pid ($pkg)"
                return 0
            fi
            stop_fas
        fi
    fi

    log "Starting Encore FAS governor on PID $target_pid ($pkg) @ ${fps}fps"
    nohup "${MODDIR}/bin/fas_governor" start "$target_pid" "$fps" "$pkg" </dev/null >/dev/null 2>&1 &
}

stop_fas() {
    if [ -x "${MODDIR}/bin/fas_governor" ]; then
        "${MODDIR}/bin/fas_governor" stop >/dev/null 2>&1
    fi
    if [ -f "${DATA_DIR}/fas_governor.pid" ]; then
        local p=$(cat "${DATA_DIR}/fas_governor.pid" 2>/dev/null)
        [ -n "$p" ] && kill -15 "$p" 2>/dev/null
        rm -f "${DATA_DIR}/fas_governor.pid"
    fi
    log "Encore FAS governor stopped"
}

show_toast_popup() {
    # Check if disabled in config
    if [ -f "$CONFIG_FILE" ]; then
        if grep -q '"toast_notifications": false' "$CONFIG_FILE" 2>/dev/null; then
            return 0
        fi
    fi
    local toast_text="$1"
    local mode="${2:-}"

    # Distinct Haptic feedback per mode
    if [ "$mode" = "game" ]; then
        # Double pulse for Game Mode (100ms on, 100ms pause, 140ms on)
        (
            cmd vibrator_manager synced oneshot 100 >/dev/null 2>&1
            sleep 0.1
            cmd vibrator_manager synced oneshot 140 >/dev/null 2>&1
        ) &
    elif [ "$mode" = "battery" ]; then
        cmd vibrator_manager synced oneshot 40 >/dev/null 2>&1 &
    else
        cmd vibrator_manager synced oneshot 60 >/dev/null 2>&1 &
    fi

    # Show real on-screen Toast Popup via bellavita.toast
    if pm path bellavita.toast >/dev/null 2>&1; then
        am start -n bellavita.toast/.MainActivity -a android.intent.action.MAIN -e toasttext "$toast_text" >/dev/null 2>&1 &
    fi
}

apply_game() {
    local pkg="$1"

    # 1. CPU CASS & UCLAMP
    sysctl -w kernel.sched_util_clamp_min_rt_default=160 >/dev/null 2>&1
    sysctl -w kernel.sched_util_clamp_min=128 >/dev/null 2>&1
    set_uclamp "top-app"           35  max  1  1
    set_uclamp "foreground"        20  60   0  0
    set_uclamp "background"        0   20   0  0
    set_uclamp "system-background" 5   30   0  0
    set_uclamp "restricted"        0   20   0  0

    # 2. Schedutil Governors (Instant Ramp & Anti-Stutter)
    echo 0 > "${SYS_CPU}/cpufreq/policy0/schedutil/up_rate_limit_us" 2>/dev/null
    echo 40000 > "${SYS_CPU}/cpufreq/policy0/schedutil/down_rate_limit_us" 2>/dev/null
    echo 85 > "${SYS_CPU}/cpufreq/policy0/schedutil/hispeed_load" 2>/dev/null
    echo 1516800 > "${SYS_CPU}/cpufreq/policy0/schedutil/hispeed_freq" 2>/dev/null

    echo 0 > "${SYS_CPU}/cpufreq/policy4/schedutil/up_rate_limit_us" 2>/dev/null
    echo 50000 > "${SYS_CPU}/cpufreq/policy4/schedutil/down_rate_limit_us" 2>/dev/null
    echo 80 > "${SYS_CPU}/cpufreq/policy4/schedutil/hispeed_load" 2>/dev/null
    echo 2092800 > "${SYS_CPU}/cpufreq/policy4/schedutil/hispeed_freq" 2>/dev/null

    # 3. GPU Tuning (Adreno 630 kgsl-3d0)
    echo 5 > "${SYS_GPU}/min_pwrlevel" 2>/dev/null
    echo 0 > "${SYS_GPU}/max_pwrlevel" 2>/dev/null
    echo 4 > "${SYS_GPU}/default_pwrlevel" 2>/dev/null
    echo 80 > "${SYS_GPU}/idle_timer" 2>/dev/null

    # 4. Virtual Memory & ZRAM (zstd 4GB + Aggressive Swapping)
    setup_zram 4096
    sysctl -w vm.swappiness=100 >/dev/null 2>&1
    sysctl -w vm.vfs_cache_pressure=60 >/dev/null 2>&1
    sysctl -w vm.min_free_kbytes=32768 >/dev/null 2>&1
    sysctl -w vm.extra_free_kbytes=32768 >/dev/null 2>&1
    sysctl -w vm.dirty_ratio=15 >/dev/null 2>&1
    sysctl -w vm.dirty_background_ratio=5 >/dev/null 2>&1
    sysctl -w vm.page-cluster=0 >/dev/null 2>&1
    if [ -f "/proc/sys/vm/workingset_protection" ]; then
        echo 1 > /proc/sys/vm/workingset_protection 2>/dev/null
        echo 5 > /proc/sys/vm/clean_min_ratio 2>/dev/null
        echo 10 > /proc/sys/vm/clean_low_ratio 2>/dev/null
    fi

    # 5. Disable LMKD Thrashing & Low Swap Kills (Protect Foreground App)
    device_config put lmkd_native swap_free_low_percentage 0 >/dev/null 2>&1
    device_config put lmkd_native thrashing_limit 100 >/dev/null 2>&1
    device_config put lmkd_native thrashing_limit_critical 100 >/dev/null 2>&1
    device_config put lmkd_native lowmem_min_oom_score 201 >/dev/null 2>&1
    if [ -x "/data/adb/ksu/bin/resetprop" ]; then
        /data/adb/ksu/bin/resetprop persist.device_config.lmkd_native.swap_free_low_percentage 0 >/dev/null 2>&1
        /data/adb/ksu/bin/resetprop persist.device_config.lmkd_native.thrashing_limit 100 >/dev/null 2>&1
        /data/adb/ksu/bin/resetprop persist.device_config.lmkd_native.thrashing_limit_critical 100 >/dev/null 2>&1
        /data/adb/ksu/bin/resetprop persist.device_config.lmkd_native.lowmem_min_oom_score 201 >/dev/null 2>&1
        /data/adb/ksu/bin/resetprop ro.lmk.swap_free_low_percentage 0 >/dev/null 2>&1
        /data/adb/ksu/bin/resetprop ro.lmk.thrashing_limit 100 >/dev/null 2>&1
        /data/adb/ksu/bin/resetprop ro.lmk.thrashing_limit_critical 100 >/dev/null 2>&1
        /data/adb/ksu/bin/resetprop ro.lmk.lowmem_min_oom_score 201 >/dev/null 2>&1
    fi
    setprop sys.lmk.minfree_levels '2048:0,4096:100,8192:200,16384:250,32768:900,49152:950' 2>/dev/null
    setprop lmkd.reinit 1 2>/dev/null

    # 6. I/O Anxiety Scheduler
    echo anxiety > "${SYS_SDA}/queue/scheduler" 2>/dev/null
    echo 8 > "${SYS_SDA}/queue/iosched/sync_ratio" 2>/dev/null
    echo 1024 > "${SYS_SDA}/queue/read_ahead_kb" 2>/dev/null

    # 7. Drop cache & protect game process with OOM -1000
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
    [ -n "$pkg" ] && protect_game "$pkg"

    # 8. Trigger Bypass Charging if enabled & connected
    local bypass_cfg=true
    if [ -f "$CONFIG_FILE" ]; then
        if grep -q '"game_bypass_charging": false' "$CONFIG_FILE" 2>/dev/null; then
            bypass_cfg=false
        fi
    fi
    if [ "$bypass_cfg" = "true" ]; then
        set_bypass 1
    fi

    # 9. Thermal Throttling Control
    local dis_thermal=true
    if [ -f "$CONFIG_FILE" ]; then
        if grep -q '"disable_thermal_throttling": false' "$CONFIG_FILE" 2>/dev/null; then
            dis_thermal=false
        fi
    fi
    if [ "$dis_thermal" = "true" ]; then
        stop_thermal_engine
    fi

    # 10. Hardware Frame Aware Scheduling (Encore FAS)
    local fas_cfg=true
    if [ -f "$CONFIG_FILE" ]; then
        if grep -q '"encore_fas_enabled": false' "$CONFIG_FILE" 2>/dev/null; then
            fas_cfg=false
        fi
    fi
    if [ "$fas_cfg" = "true" ] && [ -n "$pkg" ]; then
        start_fas "$pkg"
    fi

    echo "game" > "${DATA_DIR}/current_mode"
    log "Profile switched to GAME (pkg: ${pkg:-manual})"

    show_toast_popup "Uclamp: Game Mode" "game"
}

apply_balance() {
    local pkg="$1"

    # Disable Bypass Charging and stop Encore FAS when leaving Game Mode
    set_bypass 0
    stop_fas

    # Restore thermal throttling if not permanently disabled
    local dis_thermal=true
    if [ -f "$CONFIG_FILE" ]; then
        if grep -q '"disable_thermal_throttling": false' "$CONFIG_FILE" 2>/dev/null; then
            dis_thermal=false
        fi
    fi
    if [ "$dis_thermal" = "false" ]; then
        start_thermal_engine
    fi

    # 1. CPU CASS & UCLAMP
    sysctl -w kernel.sched_util_clamp_min_rt_default=96 >/dev/null 2>&1
    sysctl -w kernel.sched_util_clamp_min=128 >/dev/null 2>&1
    set_uclamp "top-app"           20  max  1  1
    set_uclamp "foreground"        20  50   0  0
    set_uclamp "background"        0   50   0  0
    set_uclamp "system-background" 10  50   0  0
    set_uclamp "restricted"        0   30   0  0

    # 2. Schedutil Governors (Daily Smoothness)
    echo 500 > "${SYS_CPU}/cpufreq/policy0/schedutil/up_rate_limit_us" 2>/dev/null
    echo 20000 > "${SYS_CPU}/cpufreq/policy0/schedutil/down_rate_limit_us" 2>/dev/null
    echo 90 > "${SYS_CPU}/cpufreq/policy0/schedutil/hispeed_load" 2>/dev/null
    echo 1132800 > "${SYS_CPU}/cpufreq/policy0/schedutil/hispeed_freq" 2>/dev/null

    echo 500 > "${SYS_CPU}/cpufreq/policy4/schedutil/up_rate_limit_us" 2>/dev/null
    echo 20000 > "${SYS_CPU}/cpufreq/policy4/schedutil/down_rate_limit_us" 2>/dev/null
    echo 90 > "${SYS_CPU}/cpufreq/policy4/schedutil/hispeed_load" 2>/dev/null
    echo 1612800 > "${SYS_CPU}/cpufreq/policy4/schedutil/hispeed_freq" 2>/dev/null

    # 3. GPU Tuning
    echo 6 > "${SYS_GPU}/min_pwrlevel" 2>/dev/null
    echo 0 > "${SYS_GPU}/max_pwrlevel" 2>/dev/null
    echo 6 > "${SYS_GPU}/default_pwrlevel" 2>/dev/null
    echo 80 > "${SYS_GPU}/idle_timer" 2>/dev/null

    # 4. Virtual Memory & ZRAM
    setup_zram 4096
    sysctl -w vm.swappiness=100 >/dev/null 2>&1
    sysctl -w vm.watermark_scale_factor=15 >/dev/null 2>&1
    sysctl -w vm.vfs_cache_pressure=100 >/dev/null 2>&1
    sysctl -w vm.dirty_ratio=20 >/dev/null 2>&1
    sysctl -w vm.dirty_background_ratio=10 >/dev/null 2>&1
    sysctl -w vm.page-cluster=0 >/dev/null 2>&1
    if [ -f "/proc/sys/vm/workingset_protection" ]; then
        echo 1 > /proc/sys/vm/workingset_protection 2>/dev/null
        echo 5 > /proc/sys/vm/clean_min_ratio 2>/dev/null
        echo 10 > /proc/sys/vm/clean_low_ratio 2>/dev/null
    fi

    # 5. I/O Anxiety Scheduler
    echo anxiety > "${SYS_SDA}/queue/scheduler" 2>/dev/null
    echo 4 > "${SYS_SDA}/queue/iosched/sync_ratio" 2>/dev/null
    echo 512 > "${SYS_SDA}/queue/read_ahead_kb" 2>/dev/null

    echo "balance" > "${DATA_DIR}/current_mode"
    log "Profile switched to BALANCE (pkg: ${pkg:-manual})"
    show_toast_popup "Uclamp: Balanced" "balance"
}

apply_battery() {
    local pkg="$1"

    # Disable Bypass Charging and stop Encore FAS when leaving Game Mode
    set_bypass 0
    stop_fas

    # Restore thermal throttling if not permanently disabled
    local dis_thermal=true
    if [ -f "$CONFIG_FILE" ]; then
        if grep -q '"disable_thermal_throttling": false' "$CONFIG_FILE" 2>/dev/null; then
            dis_thermal=false
        fi
    fi
    if [ "$dis_thermal" = "false" ]; then
        start_thermal_engine
    fi

    # 1. CPU CASS & UCLAMP
    sysctl -w kernel.sched_util_clamp_min_rt_default=64 >/dev/null 2>&1
    sysctl -w kernel.sched_util_clamp_min=0 >/dev/null 2>&1
    set_uclamp "top-app"           0   80   0  0
    set_uclamp "foreground"        0   40   0  0
    set_uclamp "background"        0   20   0  0
    set_uclamp "system-background" 0   20   0  0
    set_uclamp "restricted"        0   20   0  0

    # 2. Schedutil Governors (Aggressive Powersave)
    echo 2000 > "${SYS_CPU}/cpufreq/policy0/schedutil/up_rate_limit_us" 2>/dev/null
    echo 5000 > "${SYS_CPU}/cpufreq/policy0/schedutil/down_rate_limit_us" 2>/dev/null
    echo 95 > "${SYS_CPU}/cpufreq/policy0/schedutil/hispeed_load" 2>/dev/null
    echo 902400 > "${SYS_CPU}/cpufreq/policy0/schedutil/hispeed_freq" 2>/dev/null

    echo 3000 > "${SYS_CPU}/cpufreq/policy4/schedutil/up_rate_limit_us" 2>/dev/null
    echo 5000 > "${SYS_CPU}/cpufreq/policy4/schedutil/down_rate_limit_us" 2>/dev/null
    echo 95 > "${SYS_CPU}/cpufreq/policy4/schedutil/hispeed_load" 2>/dev/null
    echo 1209600 > "${SYS_CPU}/cpufreq/policy4/schedutil/hispeed_freq" 2>/dev/null

    # 3. GPU Tuning (Capped at 520 MHz)
    echo 6 > "${SYS_GPU}/min_pwrlevel" 2>/dev/null
    echo 3 > "${SYS_GPU}/max_pwrlevel" 2>/dev/null
    echo 6 > "${SYS_GPU}/default_pwrlevel" 2>/dev/null
    echo 40 > "${SYS_GPU}/idle_timer" 2>/dev/null

    # 4. Virtual Memory & ZRAM
    sysctl -w vm.swappiness=60 >/dev/null 2>&1
    sysctl -w vm.watermark_scale_factor=10 >/dev/null 2>&1
    sysctl -w vm.vfs_cache_pressure=100 >/dev/null 2>&1

    # 5. I/O Anxiety Scheduler
    echo anxiety > "${SYS_SDA}/queue/scheduler" 2>/dev/null
    echo 2 > "${SYS_SDA}/queue/iosched/sync_ratio" 2>/dev/null
    echo 128 > "${SYS_SDA}/queue/read_ahead_kb" 2>/dev/null

    echo "battery" > "${DATA_DIR}/current_mode"
    log "Profile switched to BATTERY (pkg: ${pkg:-manual})"
    show_toast_popup "Uclamp: Battery Saver" "battery"
}

purge_ram() {
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
    log "RAM caches dropped"
}

get_state_json() {
    local cur_mode="balance"
    [ -f "${DATA_DIR}/current_mode" ] && cur_mode=$(cat "${DATA_DIR}/current_mode")

    local daemon_alive=false
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
            daemon_alive=true
        fi
    fi

    local top_pkg=$(dumpsys window displays 2>/dev/null | grep 'mFocusedApp' | head -n 1 | sed -E 's/.* u[0-9]+ ([^/]+)\/.*/\1/')
    [ -z "$top_pkg" ] && top_pkg="None"

    local ram_total=$(awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 3674)
    local ram_avail=$(awk '/MemAvailable:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 1000)
    local ram_used=$((ram_total - ram_avail))
    local ram_free="$ram_avail"
    local swap_total=$(awk '/zram0/ {print int($3/1024)}' /proc/swaps 2>/dev/null || echo 3583)
    local swap_used=$(awk '/zram0/ {print int($4/1024)}' /proc/swaps 2>/dev/null || echo 0)

    local cpu_lit=$(cat "${SYS_CPU}/cpu0/cpufreq/scaling_cur_freq" 2>/dev/null || echo 0)
    local cpu_big=$(cat "${SYS_CPU}/cpu4/cpufreq/scaling_cur_freq" 2>/dev/null || echo 0)
    local gpu_mhz=$(cat "${SYS_GPU}/clock_mhz" 2>/dev/null || cat "${SYS_GPU}/gpuclk" 2>/dev/null || echo 0)
    local gpu_pwr=$(cat "${SYS_GPU}/min_pwrlevel" 2>/dev/null || echo 6)

    local bat_lvl=$(dumpsys battery 2>/dev/null | awk '$1 == "level:" {print $2}')
    local bat_st=$(dumpsys battery 2>/dev/null | awk '$1 == "status:" {print $2}')
    local is_chg="false"
    [ "$bat_st" = "2" ] || [ "$bat_st" = "5" ] && is_chg="true"

    local wake=$(dumpsys power 2>/dev/null | grep -i 'mWakefulness=' | head -n 1 | cut -d'=' -f2)
    [ -z "$wake" ] && wake="Awake"

    local swap_alg=$(grep -o '\[[a-z0-9]*\]' "${SYS_ZRAM}/comp_algorithm" 2>/dev/null | tr -d '[]' | tr '[:lower:]' '[:upper:]')
    [ -z "$swap_alg" ] && swap_alg="ZSTD"

    local bypass_act="false"
    [ "$(cat /sys/class/power_supply/battery/input_suspend 2>/dev/null)" = "1" ] && bypass_act="true"
    local usb_online=$(cat /sys/class/power_supply/usb/online 2>/dev/null || cat /sys/class/power_supply/pc_port/online 2>/dev/null || echo 0)
    local usb_conn="false"
    [ "$usb_online" = "1" ] && usb_conn="true"

    local has_fas=false
    [ -c "/dev/encore_fas" ] && has_fas=true

    local fas_act="false"
    local fas_pid=0
    local fas_pkg=""
    local fas_fps=60
    local fas_event="STOPPED"
    local fas_boost=0
    local fas_janks=0

    local fas_state_f="${DATA_DIR}/fas_state.json"
    if [ -f "$fas_state_f" ]; then
        fas_act=$(grep '"active":' "$fas_state_f" 2>/dev/null | awk '{print $2}' | tr -d ',')
        [ -z "$fas_act" ] && fas_act="false"
        fas_pid=$(grep '"pid":' "$fas_state_f" 2>/dev/null | awk '{print $2}' | tr -d ',')
        fas_pkg=$(grep '"pkg":' "$fas_state_f" 2>/dev/null | cut -d'"' -f4)
        fas_fps=$(grep '"target_fps":' "$fas_state_f" 2>/dev/null | awk '{print $2}' | tr -d ',')
        fas_event=$(grep '"last_event":' "$fas_state_f" 2>/dev/null | cut -d'"' -f4)
        fas_boost=$(grep '"uclamp_boost":' "$fas_state_f" 2>/dev/null | awk '{print $2}' | tr -d ',')
        fas_janks=$(grep '"jank_count":' "$fas_state_f" 2>/dev/null | awk '{print $2}' | tr -d ',')
    fi

    local therm_act=true
    if [ "$(getprop init.svc.thermal-engine 2>/dev/null)" != "running" ] && [ -z "$(pidof thermal-engine 2>/dev/null)" ]; then
        therm_act=false
    fi

    cat << EOF
{
  "current_mode": "${cur_mode}",
  "daemon_alive": ${daemon_alive},
  "top_package": "${top_pkg}",
  "ram_total": ${ram_total:-0},
  "ram_used": ${ram_used:-0},
  "ram_free": ${ram_free:-0},
  "swap_total": ${swap_total:-0},
  "swap_used": ${swap_used:-0},
  "swap_alg": "${swap_alg}",
  "cpu_little_mhz": $((cpu_lit / 1000)),
  "cpu_big_mhz": $((cpu_big / 1000)),
  "gpu_mhz": ${gpu_mhz:-0},
  "gpu_pwrlevel": ${gpu_pwr:-6},
  "battery_level": ${bat_lvl:-0},
  "battery_status": ${bat_st:-1},
  "is_charging": ${is_chg},
  "is_usb_connected": ${usb_conn},
  "bypass_active": ${bypass_act},
  "thermal_active": ${therm_act},
  "wakefulness": "${wake}",
  "has_encore_fas": ${has_fas},
  "fas_active": ${fas_act:-false},
  "fas_pid": ${fas_pid:-0},
  "fas_pkg": "${fas_pkg}",
  "fas_target_fps": ${fas_fps:-60},
  "fas_last_event": "${fas_event:-STOPPED}",
  "fas_uclamp_boost": ${fas_boost:-0},
  "fas_jank_count": ${fas_janks:-0}
}
EOF
}

get_apps_json() {
    echo "["
    local first=1
    for pkg in $(cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.LAUNCHER 2>/dev/null | grep '/' | cut -d'/' -f1 | tr -d ' ' | sort -u); do
        [ "$first" -eq 1 ] && first=0 || echo ","
        local mode="balance"
        if [ -f "$GAME_APPS_FILE" ] && grep -q -F -x "$pkg" "$GAME_APPS_FILE" 2>/dev/null; then
            mode="game"
        elif [ -f "$BATTERY_APPS_FILE" ] && grep -q -F -x "$pkg" "$BATTERY_APPS_FILE" 2>/dev/null; then
            mode="battery"
        fi

        # Friendly label mapping
        local lbl="$pkg"
        case "$pkg" in
            com.miHoYo.GenshinImpact|com.cognosphere.GenshinImpact) lbl="Genshin Impact" ;;
            com.franco.kernel) lbl="Franco Kernel Manager" ;;
            tw.nekomimi.nekogram) lbl="Nekogram" ;;
            com.rifsxd.ksunext) lbl="KernelSU Next" ;;
            flar2.devcheck) lbl="DevCheck" ;;
            com.android.chrome) lbl="Chrome" ;;
            com.google.android.apps.messaging) lbl="Messages" ;;
            com.google.android.dialer) lbl="Phone" ;;
            com.google.android.contacts) lbl="Contacts" ;;
            com.google.android.calculator) lbl="Calculator" ;;
            com.google.android.calendar) lbl="Calendar" ;;
            com.google.android.deskclock) lbl="Clock" ;;
            com.android.settings) lbl="Settings" ;;
            org.lineageos.aperture) lbl="Camera" ;;
            com.shinkai.wallpapers) lbl="Wallpapers" ;;
            com.mobile.legends) lbl="Mobile Legends" ;;
            com.kurogame.wutheringwaves*) lbl="Wuthering Waves" ;;
            com.HoYoverse.hkrpg*) lbl="Honkai: Star Rail" ;;
            com.HoYoverse.Nap*) lbl="Zenless Zone Zero" ;;
            com.dts.freefireth) lbl="Free Fire" ;;
            com.tencent.ig|com.pubg.krmobile) lbl="PUBG Mobile" ;;
            com.activision.callofduty.shooter) lbl="Call of Duty Mobile" ;;
            *)
                lbl=$(echo "$pkg" | awk -F. '{print $NF}' | sed 's/^[a-z]/\U&/')
                ;;
        esac

        printf '  {"pkg":"%s","label":"%s","mode":"%s"}' "$pkg" "$lbl" "$mode"
    done
    echo ""
    echo "]"
}

get_info() {
    cat << EOF
{
  "state": $(get_state_json),
  "config": $(cat "$CONFIG_FILE" 2>/dev/null || cat "${MODDIR}/default_config.json" 2>/dev/null || echo '{}'),
  "apps": $(get_apps_json)
}
EOF
}

sync_txt_lists() {
    [ ! -f "$CONFIG_FILE" ] && return
    # Extract game_apps and battery_apps into plain text files
    awk '
        /"game_apps"/ { in_g=1; in_b=0; next }
        /"battery_apps"/ { in_g=0; in_b=1; next }
        /]/ { in_g=0; in_b=0 }
        in_g && /"/ {
            gsub(/[", \t]/, "")
            if (length($0) > 0) print > "'"$GAME_APPS_FILE"'"
        }
    ' "$CONFIG_FILE"

    awk '
        /"battery_apps"/ { in_b=1; in_g=0; next }
        /"game_apps"/ { in_b=0; in_g=0; next }
        /]/ { in_b=0; in_g=0 }
        in_b && /"/ {
            gsub(/[", \t]/, "")
            if (length($0) > 0) print > "'"$BATTERY_APPS_FILE"'"
        }
    ' "$CONFIG_FILE"
}

set_app_mode() {
    local target_pkg="$1"
    local new_mode="$2" # game | balance | battery
    [ -z "$target_pkg" ] && return

    # Remove from both lists first
    [ -f "$GAME_APPS_FILE" ] && sed -i "/^${target_pkg}$/d" "$GAME_APPS_FILE"
    [ -f "$BATTERY_APPS_FILE" ] && sed -i "/^${target_pkg}$/d" "$BATTERY_APPS_FILE"

    if [ "$new_mode" = "game" ]; then
        echo "$target_pkg" >> "$GAME_APPS_FILE"
        sort -u -o "$GAME_APPS_FILE" "$GAME_APPS_FILE"
    elif [ "$new_mode" = "battery" ]; then
        echo "$target_pkg" >> "$BATTERY_APPS_FILE"
        sort -u -o "$BATTERY_APPS_FILE" "$BATTERY_APPS_FILE"
    fi

    # Trigger immediate profile update if currently focused
    local top_pkg=$(dumpsys window displays 2>/dev/null | grep 'mFocusedApp' | head -n 1 | sed -E 's/.* u[0-9]+ ([^/]+)\/.*/\1/')
    if [ "$top_pkg" = "$target_pkg" ]; then
        if [ "$new_mode" = "game" ]; then
            apply_game "$target_pkg"
        elif [ "$new_mode" = "battery" ]; then
            apply_battery "$target_pkg"
        else
            apply_balance "$target_pkg"
        fi
    fi

    echo "OK"
}

restart_daemon() {
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
            kill -9 "$pid" 2>/dev/null
        fi
        rm -f "$PID_FILE"
    fi
    nohup /system/bin/sh "${MODDIR}/daemon.sh" </dev/null >/dev/null 2>&1 &
    echo "OK"
}

show_status() {
    echo "=========================================================="
    echo "         UCLAMP AUTO PROFILER STATUS (SDM845)             "
    echo "=========================================================="
    local cur_mode="balance"
    [ -f "${DATA_DIR}/current_mode" ] && cur_mode=$(cat "${DATA_DIR}/current_mode")
    local d_status="INACTIVE"
    if [ -f "$PID_FILE" ]; then
        local dpid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$dpid" ] && [ -d "/proc/$dpid" ]; then
            d_status="ACTIVE (PID: $dpid)"
        fi
    fi
    echo "[-] Profiler State:"
    echo "    Daemon Status  : ${d_status}"
    echo "    Active Mode    : ${cur_mode}"
    echo "    Top App        : $(dumpsys window displays 2>/dev/null | grep 'mFocusedApp' | head -n 1 | sed -E 's/.* u[0-9]+ ([^/]+)\/.*/\1/')"
    echo ""
    echo "[-] Memory & ZRAM:"
    local ram_total=$(awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
    local ram_avail=$(awk '/MemAvailable:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
    local swap_total=$(awk '/zram0/ {print int($3/1024)}' /proc/swaps 2>/dev/null || echo 0)
    local swap_used=$(awk '/zram0/ {print int($4/1024)}' /proc/swaps 2>/dev/null || echo 0)
    echo "    Physical RAM   : $((ram_total - ram_avail)) MB used / ${ram_total} MB total (Avail: ${ram_avail} MB)"
    echo "    ZRAM Swap      : ${swap_used} MB used / ${swap_total} MB total"
    echo ""
    echo "[-] Hardware Clocks:"
    local cpu_lit=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo 0)
    local cpu_big=$(cat /sys/devices/system/cpu/cpu4/cpufreq/scaling_cur_freq 2>/dev/null || echo 0)
    local gpu_clk=$(cat /sys/class/kgsl/kgsl-3d0/clock_mhz 2>/dev/null || echo 0)
    local gpu_pwr=$(cat /sys/class/kgsl/kgsl-3d0/min_pwrlevel 2>/dev/null || echo 0)
    echo "    CPU Little     : $((cpu_lit / 1000)) MHz"
    echo "    CPU Big        : $((cpu_big / 1000)) MHz"
    echo "    GPU Clock      : ${gpu_clk} MHz (pwrlevel floor: ${gpu_pwr})"
    echo ""
    echo "[-] UCLAMP Top-App :"
    echo "    min: $(cat /dev/cpuset/top-app/uclamp.min 2>/dev/null)  max: $(cat /dev/cpuset/top-app/uclamp.max 2>/dev/null)  boost: $(cat /dev/cpuset/top-app/uclamp.boosted 2>/dev/null)  ls: $(cat /dev/cpuset/top-app/uclamp.latency_sensitive 2>/dev/null)"
    echo ""
    local bypass_st="DISABLED"
    [ "$(cat /sys/class/power_supply/battery/input_suspend 2>/dev/null)" = "1" ] && bypass_st="ACTIVE (⚡ Hardware Direct Power)"
    local bat_lvl=$(dumpsys battery 2>/dev/null | awk '$1 == "level:" {print $2}')
    echo "[-] Power & Battery:"
    echo "    Bypass Charging: ${bypass_st}"
    echo "    Battery Level  : ${bat_lvl:-0}%"
    echo ""
    local fas_st="NOT SUPPORTED (no /dev/encore_fas in kernel)"
    if [ -c "/dev/encore_fas" ]; then
        fas_st="STANDBY (/dev/encore_fas ready)"
        local fas_state_f="${DATA_DIR}/fas_state.json"
        if [ -f "$fas_state_f" ]; then
            local is_act=$(grep '"active":' "$fas_state_f" 2>/dev/null | awk '{print $2}' | tr -d ',')
            if [ "$is_act" = "true" ]; then
                local f_pid=$(grep '"pid":' "$fas_state_f" 2>/dev/null | awk '{print $2}' | tr -d ',')
                local f_pkg=$(grep '"pkg":' "$fas_state_f" 2>/dev/null | cut -d'"' -f4)
                local f_fps=$(grep '"target_fps":' "$fas_state_f" 2>/dev/null | awk '{print $2}' | tr -d ',')
                local f_ev=$(grep '"last_event":' "$fas_state_f" 2>/dev/null | cut -d'"' -f4)
                local f_bst=$(grep '"uclamp_boost":' "$fas_state_f" 2>/dev/null | awk '{print $2}' | tr -d ',')
                local f_jk=$(grep '"jank_count":' "$fas_state_f" 2>/dev/null | awk '{print $2}' | tr -d ',')
                fas_st="ACTIVE (PID: ${f_pid} [${f_pkg}], Target: ${f_fps} FPS, Event: ${f_ev}, Boost: ${f_bst}, Drops: ${f_jk})"
            fi
        fi
    fi
    echo "[-] Frame-Aware Scheduling (Encore FAS):"
    echo "    Encore FAS     : ${fas_st}"
    echo ""
    local therm_st="ENABLED (thermal-engine active)"
    if [ "$(getprop init.svc.thermal-engine 2>/dev/null)" != "running" ]; then
        therm_st="DISABLED (⚡ Unthrottled full performance)"
    fi
    echo "[-] Thermal Management:"
    echo "    Thermal Engine : ${therm_st}"
    echo "=========================================================="
}

extract_icons() {
    local icons_dir="${MODDIR}/webroot/icons"
    mkdir -p "$icons_dir" 2>/dev/null
    local db="/data/data/com.google.android.apps.nexuslauncher/databases/app_icons.db"
    if [ -f "$db" ] && command -v sqlite3 >/dev/null 2>&1 && command -v xxd >/dev/null 2>&1; then
        sqlite3 "$db" "SELECT componentName, quote(icon) FROM icons WHERE icon IS NOT NULL;" 2>/dev/null | while IFS='|' read -r comp hex; do
            local pkg="${comp%%/*}"
            [ -z "$pkg" ] && continue
            local out="${icons_dir}/${pkg}.png"
            if [ ! -s "$out" ]; then
                local hex_clean="${hex#X\'}"
                hex_clean="${hex_clean%\'}"
                [ -n "$hex_clean" ] && echo -n "$hex_clean" | xxd -r -p > "$out" 2>/dev/null
            fi
        done
        chmod 644 "${icons_dir}"/*.png 2>/dev/null
    fi
}

# ------------------------------------------------------------------------------
# Entrypoint
# ------------------------------------------------------------------------------
case "$1" in
    game)
        apply_game "$2"
        ;;
    battery)
        apply_battery "$2"
        ;;
    purge)
        purge_ram
        ;;
    status|info)
        show_status
        ;;
    get_state)
        get_state_json
        ;;
    get_apps)
        get_apps_json
        ;;
    get_info)
        get_info
        ;;
    extract_icons)
        extract_icons
        ;;
    set_app)
        set_app_mode "$2" "$3"
        ;;
    sync_config)
        sync_txt_lists
        ;;
    restart_daemon)
        restart_daemon
        ;;
    set_bypass|bypass)
        set_bypass "$2"
        ;;
    set_thermal|thermal)
        set_thermal "$2"
        ;;
    start_fas)
        start_fas "$2" "$3"
        ;;
    stop_fas)
        stop_fas
        ;;
    fas_status)
        if [ -x "${MODDIR}/bin/fas_governor" ]; then
            "${MODDIR}/bin/fas_governor" status
        else
            echo '{"active":false}'
        fi
        ;;
    monitor|mon)
        if [ -x "${MODDIR}/monitor.sh" ]; then
            exec /bin/sh "${MODDIR}/monitor.sh" "$2" "$3"
        elif [ -x "${0%/*}/monitor.sh" ]; then
            exec /bin/sh "${0%/*}/monitor.sh" "$2" "$3"
        else
            echo "[-] monitor.sh not found in ${MODDIR}"
        fi
        ;;
    balance|*)
        apply_balance "$2"
        ;;
esac
