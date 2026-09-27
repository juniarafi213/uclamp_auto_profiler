#!/system/bin/sh
# KernelSU Next Action Script
MODDIR="/data/adb/modules/uclamp_auto_profiler"
DATA_DIR="/data/adb/uclamp_profiler"

echo "[*] UCLAMP Profiler Action Triggered"
# Purge RAM caches as quick action
sh "${MODDIR}/tuner.sh" purge
echo "[✓] RAM Caches Purged! Active Mode: $(cat ${DATA_DIR}/current_mode 2>/dev/null || echo 'balance')"
