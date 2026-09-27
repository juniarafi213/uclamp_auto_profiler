#!/system/bin/sh
# KernelSU Next Service Script for UCLAMP Auto Profiler

MODDIR="${0%/*}"

# Wait until Android has fully finished booting
while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 2
done
sleep 3

# Initialize LMKD Anti-Kill properties for SDM845 Gaming
if [ -x "/data/adb/ksu/bin/resetprop" ]; then
    /data/adb/ksu/bin/resetprop ro.lmk.swap_free_low_percentage 0 >/dev/null 2>&1
    /data/adb/ksu/bin/resetprop ro.lmk.thrashing_limit_critical 0 >/dev/null 2>&1
    /data/adb/ksu/bin/resetprop ro.lmk.thrashing_limit 0 >/dev/null 2>&1
fi

# Start Autonomous Daemon
nohup /system/bin/sh "${MODDIR}/daemon.sh" </dev/null >/dev/null 2>&1 &
