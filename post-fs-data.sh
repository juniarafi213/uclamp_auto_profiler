#!/system/bin/sh
# KernelSU Next post-fs-data Script for UCLAMP Auto Profiler
# Runs before zygote and system services start

MODDIR="${0%/*}"

# Configure LMKD anti-kill properties early before lmkd reads properties
if [ -x "/data/adb/ksu/bin/resetprop" ]; then
    /data/adb/ksu/bin/resetprop persist.device_config.lmkd_native.swap_free_low_percentage 0
    /data/adb/ksu/bin/resetprop persist.device_config.lmkd_native.thrashing_limit 100
    /data/adb/ksu/bin/resetprop persist.device_config.lmkd_native.thrashing_limit_critical 100
    /data/adb/ksu/bin/resetprop persist.device_config.lmkd_native.lowmem_min_oom_score 201
    /data/adb/ksu/bin/resetprop ro.lmk.swap_free_low_percentage 0
    /data/adb/ksu/bin/resetprop ro.lmk.thrashing_limit 100
    /data/adb/ksu/bin/resetprop ro.lmk.thrashing_limit_critical 100
    /data/adb/ksu/bin/resetprop ro.lmk.lowmem_min_oom_score 201
fi
