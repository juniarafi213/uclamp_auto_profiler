#!/system/bin/sh
# UCLAMP Auto Profiler Installation Script

ui_print "****************************************"
ui_print "*        UCLAMP AUTO PROFILER          *"
ui_print "*   Sony SDM845 Autonomous Gaming Tuner*"
ui_print "****************************************"

# Install on-screen Toast Popup helper APK
if [ -f "$MODPATH/toast.apk" ]; then
    ui_print "- Installing on-screen Toast Popup helper..."
    pm install -r "$MODPATH/toast.apk" >/dev/null 2>&1 && ui_print "  ✓ Toast Popup helper installed" || ui_print "  ! Toast install fallback"
fi

# Set permissions
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/tuner.sh" 0 0 0755
set_perm "$MODPATH/daemon.sh" 0 0 0755
set_perm "$MODPATH/monitor.sh" 0 0 0755
[ -d "$MODPATH/bin" ] && set_perm_recursive "$MODPATH/bin" 0 0 0755 0755
[ -d "$MODPATH/system/bin" ] && set_perm_recursive "$MODPATH/system/bin" 0 0 0755 0755

# Check Encore FAS interface
if [ -e "/dev/encore_fas" ]; then
    ui_print "- Hardware Frame Aware Scheduling: /dev/encore_fas DETECTED ✓"
else
    ui_print "- Hardware Frame Aware Scheduling: /dev/encore_fas not found (standby)"
fi

ui_print "- Thermal Engine Control: INTEGRATED ✓"
ui_print "- Sony LRC Game Auto-Cut Charging: INTEGRATED ✓"
if [ -x "$MODPATH/bin/uclampd" ]; then
    ui_print "- Native Rust Engine: uclampd (aarch64) DETECTED ✓"
fi
ui_print "- Installation Complete!"
