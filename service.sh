#!/system/bin/sh
# KernelSU Next Service Script for UCLAMP Auto Profiler

MODDIR="${0%/*}"

# Wait until Android has fully finished booting
while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 2
done
sleep 3

# Start Autonomous Daemon
nohup /system/bin/sh "${MODDIR}/daemon.sh" </dev/null >/dev/null 2>&1 &
