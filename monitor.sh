#!/bin/sh
# ==============================================================================
# SONY XPERIA SDM845 (Tama) - Real-time Hardware & Kernel Monitor
# CPU / GPU / Thermal / Memory / UCLAMP / Encore FAS / Power Delivery
# ==============================================================================

# If executed on desktop host (PC), automatically run via ADB
if ! command -v getprop >/dev/null 2>&1; then
    if command -v adb >/dev/null 2>&1; then
        if ! adb get-state >/dev/null 2>&1; then
            echo "[!] No ADB device connected or authorized."
            exit 1
        fi
        adb push "$0" /data/local/tmp/monitor.sh >/dev/null 2>&1
        exec adb shell su -c "sh /data/local/tmp/monitor.sh \"$@\""
    else
        echo "[!] adb not found on host machine."
        exit 1
    fi
fi

# Ensure root
if [ "$(id -u)" != "0" ]; then
    echo "[!] Root access required. Rerun with: su -c $0"
    exit 1
fi

# Configuration & Defaults
INTERVAL=1
ONCE=0

while [ $# -gt 0 ]; do
    case "$1" in
        -i|--interval)
            INTERVAL="$2"
            shift 2
            ;;
        -1|--once)
            ONCE=1
            shift
            ;;
        -h|--help)
            echo "Sony SDM845 Real-time Hardware Monitor"
            echo "Usage: uclamp monitor [-i seconds] [-1] [-h]  (or ./monitor.sh on PC)"
            echo "  -i, --interval <sec>   Refresh interval in seconds (default: 1)"
            echo "  -1, --once             Print metrics once and exit"
            echo "  -h, --help             Show this help message"
            exit 0
            ;;
        *)
            shift
            ;;
    esac
done

# ANSI Color Codes
C_RST="\033[0m"
C_BOLD="\033[1m"
C_DIM="\033[2m"
C_CYAN="\033[1;36m"
C_GRN="\033[1;32m"
C_YEL="\033[1;33m"
C_RED="\033[1;31m"
C_MAG="\033[1;35m"
C_BLU="\033[1;34m"
C_WHT="\033[1;37m"
C_GRAY="\033[38;5;242m"

# Hardware limits for SDM845
LITTLE_MAX_KHZ=1766400
BIG_MAX_KHZ=2803200
GPU_MAX_MHZ=710

# Dynamic Thermal Zone Discovery
TZ_SILVER=""
TZ_GOLD=""
TZ_GPU=""
TZ_BATTERY=""

for z in /sys/class/thermal/thermal_zone*; do
    if [ -f "$z/type" ]; then
        t=$(cat "$z/type" 2>/dev/null)
        case "$t" in
            *silver*usr*)   [ -z "$TZ_SILVER" ] && TZ_SILVER="$z/temp" ;;
            *gold*usr*)     [ -z "$TZ_GOLD" ] && TZ_GOLD="$z/temp" ;;
            *gpu0-usr*)     [ -z "$TZ_GPU" ] && TZ_GPU="$z/temp" ;;
            *battery*)      [ -z "$TZ_BATTERY" ] && TZ_BATTERY="$z/temp" ;;
        esac
    fi
done

# Fallbacks if specific user zones aren't matched
[ -z "$TZ_SILVER" ] && TZ_SILVER="/sys/class/thermal/thermal_zone1/temp"
[ -z "$TZ_GOLD" ] && TZ_GOLD="/sys/class/thermal/thermal_zone10/temp"
[ -z "$TZ_GPU" ] && TZ_GPU="/sys/class/thermal/thermal_zone11/temp"
[ -z "$TZ_BATTERY" ] && TZ_BATTERY="/sys/class/thermal/thermal_zone72/temp"

# CPU Load tracking variables
PREV_TOTAL=0
PREV_IDLE=0

# Gauge generator: render bar [■■■■■······]
draw_bar() {
    # $1: current val, $2: max val, $3: bar width, $4: color
    local cur=$1 max=$2 width=${3:-12} color=${4:-$C_CYAN}
    [ "$max" -le 0 ] && max=1
    local filled=$(( cur * width / max ))
    [ "$filled" -gt "$width" ] && filled=$width
    [ "$filled" -lt 0 ] && filled=0
    local empty=$(( width - filled ))
    
    local bar_fill=""
    local bar_empty=""
    local i=0
    while [ $i -lt $filled ]; do bar_fill="${bar_fill}■"; i=$((i + 1)); done
    i=0
    while [ $i -lt $empty ]; do bar_empty="${bar_empty}·"; i=$((i + 1)); done
    
    printf "${color}%s${C_GRAY}%s${C_RST}" "$bar_fill" "$bar_empty"
}

# Trap SIGINT to restore terminal
trap 'printf "\033[?25h\n"; exit 0' INT TERM

# Hide cursor
printf "\033[?25l"

# Main render routine
render() {
    # 1. CPU Total Load from /proc/stat
    read -r _ u n s id io ir sir st _ < /proc/stat
    local tot=$((u + n + s + id + io + ir + sir + st))
    local idle_now=$((id + io))
    local cpu_load=0
    if [ "$PREV_TOTAL" -gt 0 ]; then
        local d_tot=$((tot - PREV_TOTAL))
        local d_idle=$((idle_now - PREV_IDLE))
        if [ "$d_tot" -gt 0 ]; then
            cpu_load=$(( (d_tot - d_idle) * 100 / d_tot ))
        fi
    fi
    PREV_TOTAL=$tot
    PREV_IDLE=$idle_now

    # 2. CPU Frequencies
    local c0 c1 c2 c3 c4 c5 c6 c7
    c0=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo 0)
    c1=$(cat /sys/devices/system/cpu/cpu1/cpufreq/scaling_cur_freq 2>/dev/null || echo 0)
    c2=$(cat /sys/devices/system/cpu/cpu2/cpufreq/scaling_cur_freq 2>/dev/null || echo 0)
    c3=$(cat /sys/devices/system/cpu/cpu3/cpufreq/scaling_cur_freq 2>/dev/null || echo 0)
    c4=$(cat /sys/devices/system/cpu/cpu4/cpufreq/scaling_cur_freq 2>/dev/null || echo 0)
    c5=$(cat /sys/devices/system/cpu/cpu5/cpufreq/scaling_cur_freq 2>/dev/null || echo 0)
    c6=$(cat /sys/devices/system/cpu/cpu6/cpufreq/scaling_cur_freq 2>/dev/null || echo 0)
    c7=$(cat /sys/devices/system/cpu/cpu7/cpufreq/scaling_cur_freq 2>/dev/null || echo 0)

    local gov_lit gov_big
    gov_lit=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor 2>/dev/null || echo "schedutil")
    gov_big=$(cat /sys/devices/system/cpu/cpufreq/policy4/scaling_governor 2>/dev/null || echo "schedutil")

    # 3. GPU Metrics
    local gpu_clk gpu_busy gpu_pwr
    gpu_clk=$(cat /sys/class/kgsl/kgsl-3d0/clock_mhz 2>/dev/null || cat /sys/class/kgsl/kgsl-3d0/gpuclk 2>/dev/null || echo 0)
    [ "$gpu_clk" -gt 1000000 ] && gpu_clk=$((gpu_clk / 1000000))
    gpu_busy=$(cat /sys/class/kgsl/kgsl-3d0/gpu_busy_percentage 2>/dev/null | tr -d ' %' || echo 0)
    [ -z "$gpu_busy" ] && gpu_busy=0
    gpu_pwr=$(cat /sys/class/kgsl/kgsl-3d0/pwrlevel 2>/dev/null || echo 6)

    # 4. Temperatures
    local temp_lit temp_big temp_gpu temp_bat
    temp_lit=$(( $(cat "$TZ_SILVER" 2>/dev/null || echo 30000) / 1000 ))
    temp_big=$(( $(cat "$TZ_GOLD" 2>/dev/null || echo 30000) / 1000 ))
    temp_gpu=$(( $(cat "$TZ_GPU" 2>/dev/null || echo 30000) / 1000 ))
    temp_bat=$(( $(cat /sys/class/power_supply/battery/temp 2>/dev/null || echo 300) / 10 ))

    # 5. Memory & ZRAM
    local ram_tot ram_avail ram_used ram_pct
    ram_tot=$(awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 3674)
    ram_avail=$(awk '/MemAvailable:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 1000)
    ram_used=$((ram_tot - ram_avail))
    ram_pct=$((ram_used * 100 / (ram_tot > 0 ? ram_tot : 1)))

    local zram_tot zram_used zram_alg
    zram_tot=$(awk '/zram0/ {print int($3/1024)}' /proc/swaps 2>/dev/null || echo 4095)
    zram_used=$(awk '/zram0/ {print int($4/1024)}' /proc/swaps 2>/dev/null || echo 0)
    zram_alg=$(grep -o '\[[a-z0-9]*\]' /sys/block/zram0/comp_algorithm 2>/dev/null | tr -d '[]' | tr '[:lower:]' '[:upper:]')
    [ -z "$zram_alg" ] && zram_alg="ZSTD"

    # 6. Battery & Power Delivery
    local bat_lvl bat_cur bat_volt bat_susp bat_power_w
    bat_lvl=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null || echo 0)
    bat_cur=$(cat /sys/class/power_supply/battery/current_now 2>/dev/null || echo 0)
    bat_volt=$(cat /sys/class/power_supply/battery/voltage_now 2>/dev/null || echo 0)
    bat_susp=$(cat /sys/class/power_supply/battery/input_suspend 2>/dev/null || echo 0)
    
    # Calculate mA and W
    local cur_ma=$((bat_cur / 1000))
    local volt_v=$(awk "BEGIN {printf \"%.2f\", $bat_volt / 1000000}")
    local watt_w=$(awk "BEGIN {printf \"%.2f\", ($cur_ma * ($bat_volt / 1000000)) / 1000}")

    local pwr_status_str="Discharging"
    local pwr_color="$C_YEL"
    if [ "$bat_susp" = "1" ]; then
        pwr_status_str="⚡ BYPASS ACTIVE (Direct USB Power)"
        pwr_color="$C_GRN"
    elif [ "$cur_ma" -gt 0 ] || [ "$(cat /sys/class/power_supply/battery/status 2>/dev/null)" = "Charging" ]; then
        pwr_status_str="⚡ Fast Charging"
        pwr_color="$C_CYAN"
    fi

    # 7. UCLAMP & Auto Profiler State
    local cur_mode="balance"
    [ -f "/data/adb/uclamp_profiler/current_mode" ] && cur_mode=$(cat "/data/adb/uclamp_profiler/current_mode")
    local uclamp_min=$(cat /dev/cpuset/top-app/uclamp.min 2>/dev/null || echo "0.00")
    local uclamp_max=$(cat /dev/cpuset/top-app/uclamp.max 2>/dev/null || echo "max")
    local top_pkg=$(dumpsys window displays 2>/dev/null | grep 'mFocusedApp' | head -n 1 | sed -E 's/.* u[0-9]+ ([^/]+)\/.*/\1/')
    [ -z "$top_pkg" ] && top_pkg="Launcher"

    local mode_badge="[⚖️ DAILY]"
    local mode_color="$C_CYAN"
    if [ "$cur_mode" = "game" ]; then
        mode_badge="[🎮 GAME]"
        mode_color="$C_GRN"
    elif [ "$cur_mode" = "battery" ]; then
        mode_badge="[🔋 BATTERY]"
        mode_color="$C_YEL"
    fi

    # 8. Encore FAS Telemetry
    local fas_state_f="/data/adb/uclamp_profiler/fas_state.json"
    local fas_active="false"
    local fas_fps=0
    local fas_event="STANDBY"
    local fas_boost=0
    local fas_drops=0
    if [ -f "$fas_state_f" ]; then
        fas_active=$(grep '"active":' "$fas_state_f" 2>/dev/null | awk '{print $2}' | tr -d ',')
        fas_fps=$(grep '"target_fps":' "$fas_state_f" 2>/dev/null | awk '{print $2}' | tr -d ',')
        fas_event=$(grep '"last_event":' "$fas_state_f" 2>/dev/null | cut -d'"' -f4)
        fas_boost=$(grep '"uclamp_boost":' "$fas_state_f" 2>/dev/null | awk '{print $2}' | tr -d ',')
        fas_drops=$(grep '"jank_count":' "$fas_state_f" 2>/dev/null | awk '{print $2}' | tr -d ',')
    fi

    # Clear screen and draw
    if [ "$ONCE" -eq 0 ]; then
        printf "\033[H\033[J"
    fi

    printf "${C_CYAN}┌────────────────────────────────────────────────────────────────────────┐${C_RST}\n"
    printf "${C_CYAN}│${C_RST} ${C_BOLD}⚡ SONY XPERIA SDM845 MONITOR (Tama)${C_RST}          ${mode_color}%-14s${C_RST} ${C_GRAY}%s${C_RST} ${C_CYAN}│${C_RST}\n" "$mode_badge" "$(date '+%H:%M:%S')"
    printf "${C_CYAN}├────────────────────────────────────────────────────────────────────────┤${C_RST}\n"

    # CPU Header
    local c_cpu_clr="$C_GRN"
    [ "$cpu_load" -gt 60 ] && c_cpu_clr="$C_YEL"
    [ "$cpu_load" -gt 85 ] && c_cpu_clr="$C_RED"
    printf "${C_CYAN}│${C_RST} ${C_BOLD}CPU (Kryo 385 8-Core)${C_RST}   Total Load: ${c_cpu_clr}%3d%%${C_RST} %s   Top: ${C_WHT}%-14s${C_RST} ${C_CYAN}│${C_RST}\n" \
        "$cpu_load" "$(draw_bar "$cpu_load" 100 10 "$c_cpu_clr")" "${top_pkg##*.}"

    # Little Cluster
    printf "${C_CYAN}│${C_RST}  ${C_CYAN}Little Cluster${C_RST} (0-3)  Gov: ${C_DIM}%-9s${C_RST} Temp: ${C_YEL}%2d°C${C_RST}                     ${C_CYAN}│${C_RST}\n" \
        "$gov_lit" "$temp_lit"
    printf "${C_CYAN}│${C_RST}   #0: %s %4d MHz  #1: %s %4d MHz                   ${C_CYAN}│${C_RST}\n" \
        "$(draw_bar $((c0 / 1000)) $((LITTLE_MAX_KHZ / 1000)) 8 "$C_CYAN")" "$((c0 / 1000))" \
        "$(draw_bar $((c1 / 1000)) $((LITTLE_MAX_KHZ / 1000)) 8 "$C_CYAN")" "$((c1 / 1000))"
    printf "${C_CYAN}│${C_RST}   #2: %s %4d MHz  #3: %s %4d MHz                   ${C_CYAN}│${C_RST}\n" \
        "$(draw_bar $((c2 / 1000)) $((LITTLE_MAX_KHZ / 1000)) 8 "$C_CYAN")" "$((c2 / 1000))" \
        "$(draw_bar $((c3 / 1000)) $((LITTLE_MAX_KHZ / 1000)) 8 "$C_CYAN")" "$((c3 / 1000))"

    # Big Cluster
    printf "${C_CYAN}│${C_RST}  ${C_MAG}Big Cluster${C_RST}    (4-7)  Gov: ${C_DIM}%-9s${C_RST} Temp: ${C_YEL}%2d°C${C_RST}                     ${C_CYAN}│${C_RST}\n" \
        "$gov_big" "$temp_big"
    printf "${C_CYAN}│${C_RST}   #4: %s %4d MHz  #5: %s %4d MHz                   ${C_CYAN}│${C_RST}\n" \
        "$(draw_bar $((c4 / 1000)) $((BIG_MAX_KHZ / 1000)) 8 "$C_MAG")" "$((c4 / 1000))" \
        "$(draw_bar $((c5 / 1000)) $((BIG_MAX_KHZ / 1000)) 8 "$C_MAG")" "$((c5 / 1000))"
    printf "${C_CYAN}│${C_RST}   #6: %s %4d MHz  #7: %s %4d MHz                   ${C_CYAN}│${C_RST}\n" \
        "$(draw_bar $((c6 / 1000)) $((BIG_MAX_KHZ / 1000)) 8 "$C_MAG")" "$((c6 / 1000))" \
        "$(draw_bar $((c7 / 1000)) $((BIG_MAX_KHZ / 1000)) 8 "$C_MAG")" "$((c7 / 1000))"
    printf "${C_CYAN}├────────────────────────────────────────────────────────────────────────┤${C_RST}\n"

    # GPU Adreno 630
    local c_gpu_clr="$C_GRN"
    [ "$gpu_busy" -gt 60 ] && c_gpu_clr="$C_YEL"
    [ "$gpu_busy" -gt 85 ] && c_gpu_clr="$C_RED"
    printf "${C_CYAN}│${C_RST} ${C_BOLD}GPU Adreno 630${C_RST}          PwrLevel: ${C_WHT}%d${C_RST}        Temp: ${C_YEL}%2d°C${C_RST}                     ${C_CYAN}│${C_RST}\n" \
        "$gpu_pwr" "$temp_gpu"
    printf "${C_CYAN}│${C_RST}  Clock: %s %3d / %3d MHz   Busy: %s %3d%%          ${C_CYAN}│${C_RST}\n" \
        "$(draw_bar "$gpu_clk" "$GPU_MAX_MHZ" 10 "$C_GRN")" "$gpu_clk" "$GPU_MAX_MHZ" \
        "$(draw_bar "$gpu_busy" 100 10 "$c_gpu_clr")" "$gpu_busy"
    printf "${C_CYAN}├────────────────────────────────────────────────────────────────────────┤${C_RST}\n"

    # Encore FAS Telemetry
    local fas_evt_color="$C_GRN"
    case "$fas_event" in
        *JANK*|*HARD*) fas_evt_color="$C_RED" ;;
        *SOFT*|*BOOST*) fas_evt_color="$C_YEL" ;;
        *PAUSED*) fas_evt_color="$C_MAG" ;;
        *RATE*) fas_evt_color="$C_CYAN" ;;
    esac
    local fas_status_str="STANDBY"
    [ "$fas_active" = "true" ] && fas_status_str="ACTIVE"

    printf "${C_CYAN}│${C_RST} ${C_BOLD}FRAME AWARE SCHEDULING (Encore FAS)${C_RST}                                     ${C_CYAN}│${C_RST}\n"
    printf "${C_CYAN}│${C_RST}  Status: %-8s  Target: ${C_WHT}%2d FPS${C_RST}     Event: ${fas_evt_color}%-12s${C_RST}         ${C_CYAN}│${C_RST}\n" \
        "$fas_status_str" "$fas_fps" "$fas_event"
    printf "${C_CYAN}│${C_RST}  UCLAMP: ${C_CYAN}min %-5s${C_RST} / max %-4s   Boost: ${C_WHT}%-3d${C_RST}    Jank Drops: ${C_YEL}%-4d${C_RST}    ${C_CYAN}│${C_RST}\n" \
        "$uclamp_min" "$uclamp_max" "$fas_boost" "$fas_drops"
    printf "${C_CYAN}├────────────────────────────────────────────────────────────────────────┤${C_RST}\n"

    # Memory & ZRAM
    printf "${C_CYAN}│${C_RST} ${C_BOLD}MEMORY & ZRAM${C_RST}                                                           ${C_CYAN}│${C_RST}\n"
    printf "${C_CYAN}│${C_RST}  RAM : %s %4d / %4d MB (%2d%%)  Free: ${C_GRN}%4d MB${C_RST}               ${C_CYAN}│${C_RST}\n" \
        "$(draw_bar "$ram_used" "$ram_tot" 12 "$C_CYAN")" "$ram_used" "$ram_tot" "$ram_pct" "$ram_avail"
    printf "${C_CYAN}│${C_RST}  ZRAM: %s %4d / %4d MB         Alg:  ${C_WHT}%-4s (Pri 32767)${C_RST}       ${C_CYAN}│${C_RST}\n" \
        "$(draw_bar "$zram_used" "$zram_tot" 12 "$C_GRN")" "$zram_used" "$zram_tot" "$zram_alg"
    printf "${C_CYAN}├────────────────────────────────────────────────────────────────────────┤${C_RST}\n"

    # Power & Battery
    printf "${C_CYAN}│${C_RST} ${C_BOLD}POWER & BATTERY${C_RST}                                                         ${C_CYAN}│${C_RST}\n"
    printf "${C_CYAN}│${C_RST}  Battery: ${C_WHT}%3d%%${C_RST} %s   State: ${pwr_color}%-32s${C_RST} ${C_CYAN}│${C_RST}\n" \
        "$bat_lvl" "$(draw_bar "$bat_lvl" 100 10 "$C_GRN")" "$pwr_status_str"
    printf "${C_CYAN}│${C_RST}  Flow   : ${C_WHT}%+5d mA${C_RST} @ ${C_WHT}%s V${C_RST} (~${C_WHT}%s W${C_RST})   Battery Temp: ${C_YEL}%2d°C${C_RST}              ${C_CYAN}│${C_RST}\n" \
        "$cur_ma" "$volt_v" "$watt_w" "$temp_bat"
    printf "${C_CYAN}└────────────────────────────────────────────────────────────────────────┘${C_RST}\n"

    if [ "$ONCE" -eq 0 ]; then
        printf "${C_GRAY} [Press Ctrl+C to exit | Refresh: %ss]${C_RST}\n" "$INTERVAL"
    fi
}

# Initial warmup for CPU diff
render >/dev/null 2>&1
sleep 0.1

if [ "$ONCE" -eq 1 ]; then
    render
    printf "\033[?25h"
    exit 0
fi

# Main interactive loop
while true; do
    render
    sleep "$INTERVAL"
done
