#!/system/bin/sh
# KernelSU Next Service Script for UCLAMP Auto Profiler

MODDIR="${0%/*}"

# Wait until Android has fully finished booting
while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 2
done
sleep 3

# Enforce LMKD Anti-Kill properties for SDM845
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

# Initial ZRAM 4096M zstd setup
/system/bin/sh "${MODDIR}/tuner.sh" setup_zram 4096 >/dev/null 2>&1

# Start Autonomous Daemon
nohup /system/bin/sh "${MODDIR}/daemon.sh" </dev/null >/dev/null 2>&1 &
