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
[ -d "$MODPATH/system/bin" ] && set_perm_recursive "$MODPATH/system/bin" 0 0 0755 0755

ui_print "- Installation Complete!"
