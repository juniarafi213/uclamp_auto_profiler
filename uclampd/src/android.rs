use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::Command;
use std::thread;
use std::time::Duration;
use crate::config::{Config, MODDIR};
use crate::sysfs::{self, read_int, read_node, write_node};

pub fn get_focused_package() -> Option<String> {
    if let Ok(out) = Command::new("dumpsys")
        .args(["window", "displays"])
        .output()
    {
        let stdout = String::from_utf8_lossy(&out.stdout);
        for line in stdout.lines() {
            if line.contains("mFocusedApp") {
                // Example format: ... u0 com.miHoYo.GenshinImpact/...
                if let Some(pos) = line.find(" u") {
                    let sub = &line[pos + 2..];
                    // Skip digits (user id) and space
                    if let Some(space_idx) = sub.find(' ') {
                        let after_space = &sub[space_idx + 1..];
                        if let Some(slash_idx) = after_space.find('/') {
                            let pkg = &after_space[..slash_idx];
                            if !pkg.is_empty() {
                                return Some(pkg.to_string());
                            }
                        }
                    }
                }
            }
        }
    }
    None
}

pub fn get_wakefulness() -> String {
    if let Ok(out) = Command::new("dumpsys").args(["power"]).output() {
        let stdout = String::from_utf8_lossy(&out.stdout);
        for line in stdout.lines() {
            if let Some(pos) = line.find("mWakefulness=") {
                let val = line[pos + 13..].split_whitespace().next().unwrap_or("Awake");
                return val.trim().to_string();
            }
        }
    }
    "Awake".to_string()
}

pub fn get_battery_info() -> (u32, i32, bool) {
    let capacity = read_int("/sys/class/power_supply/battery/capacity").unwrap_or(0) as u32;
    let status_str = read_node("/sys/class/power_supply/battery/status").unwrap_or_default();
    let is_chg = status_str == "Charging" || status_str == "Full";
    let status_code = match status_str.as_str() {
        "Charging" => 2,
        "Discharging" => 3,
        "Not charging" => 4,
        "Full" => 5,
        _ => 1,
    };
    (capacity, status_code, is_chg)
}

pub fn show_toast_popup(text: &str, mode: &str) {
    let cfg = Config::load();
    if !cfg.toast_notifications {
        return;
    }

    let mode_str = mode.to_string();
    thread::spawn(move || {
        if mode_str == "game" {
            let _ = Command::new("cmd")
                .args(["vibrator_manager", "synced", "oneshot", "100"])
                .output();
            thread::sleep(Duration::from_millis(100));
            let _ = Command::new("cmd")
                .args(["vibrator_manager", "synced", "oneshot", "140"])
                .output();
        } else if mode_str == "battery" {
            let _ = Command::new("cmd")
                .args(["vibrator_manager", "synced", "oneshot", "40"])
                .output();
        } else {
            let _ = Command::new("cmd")
                .args(["vibrator_manager", "synced", "oneshot", "60"])
                .output();
        }
    });

    let _ = Command::new("am")
        .args([
            "start",
            "-n",
            "bellavita.toast/.MainActivity",
            "-a",
            "android.intent.action.MAIN",
            "-e",
            "toasttext",
            text,
        ])
        .spawn();
}

pub fn protect_game_process(pkg: &str) {
    if pkg.is_empty() {
        return;
    }

    if let Ok(entries) = fs::read_dir("/proc") {
        for entry in entries.flatten() {
            let path = entry.path();
            if !path.is_dir() {
                continue;
            }

            let pid_str = match path.file_name().and_then(|n| n.to_str()) {
                Some(s) => s,
                None => continue,
            };

            if pid_str.parse::<u32>().is_err() {
                continue;
            }

            let cmdline_path = path.join("cmdline");
            if let Ok(cmdline) = fs::read_to_string(&cmdline_path) {
                let cmd = cmdline.trim_matches('\0');
                if cmd == pkg || cmd.starts_with(&format!("{}:", pkg)) {
                    let oom_path = path.join("oom_score_adj");
                    let _ = fs::set_permissions(&oom_path, PermissionsExt::from_mode(0o666));
                    let _ = write_node(oom_path.to_str().unwrap_or(""), "-1000");
                    let _ = fs::set_permissions(&oom_path, PermissionsExt::from_mode(0o444));

                    let oom_adj_path = path.join("oom_adj");
                    let _ = write_node(oom_adj_path.to_str().unwrap_or(""), "-17");

                    let _ = write_node("/dev/cpuset/top-app/tasks", pid_str);
                    let _ = Command::new("renice").args(["-n", "-20", "-p", pid_str]).output();
                }
            }
        }
    }
}

pub fn apply_lmkd_props() {
    let resetprop = "/data/adb/ksu/bin/resetprop";
    let props = [
        ("persist.device_config.lmkd_native.swap_free_low_percentage", "0"),
        ("persist.device_config.lmkd_native.thrashing_limit", "100"),
        ("persist.device_config.lmkd_native.thrashing_limit_critical", "100"),
        ("persist.device_config.lmkd_native.lowmem_min_oom_score", "201"),
        ("ro.lmk.swap_free_low_percentage", "0"),
        ("ro.lmk.thrashing_limit", "100"),
        ("ro.lmk.thrashing_limit_critical", "100"),
        ("ro.lmk.lowmem_min_oom_score", "201"),
    ];

    if Path::new(resetprop).exists() {
        for (k, v) in props {
            let _ = Command::new(resetprop).args([k, v]).output();
        }
    }

    let _ = Command::new("device_config").args(["put", "lmkd_native", "swap_free_low_percentage", "0"]).output();
    let _ = Command::new("device_config").args(["put", "lmkd_native", "thrashing_limit", "100"]).output();
    let _ = Command::new("device_config").args(["put", "lmkd_native", "thrashing_limit_critical", "100"]).output();
    let _ = Command::new("device_config").args(["put", "lmkd_native", "lowmem_min_oom_score", "201"]).output();
    let _ = Command::new("setprop").args(["sys.lmk.minfree_levels", "2048:0,4096:100,8192:200,16384:250,32768:900,49152:950"]).output();
    let _ = Command::new("setprop").args(["lmkd.reinit", "1"]).output();
}

pub fn purge_ram() {
    let _ = Command::new("sync").status();
    let _ = write_node("/proc/sys/vm/drop_caches", "3");
    sysfs::log("RAM caches dropped");
    println!("RAM caches dropped");
}

pub fn extract_icons() {
    let icons_dir = format!("{}/webroot/icons", MODDIR);
    let _ = fs::create_dir_all(&icons_dir);
    let db = "/data/data/com.google.android.apps.nexuslauncher/databases/app_icons.db";
    if Path::new(db).exists() {
        let script = format!(
            "sqlite3 \"{}\" \"SELECT componentName, quote(icon) FROM icons WHERE icon IS NOT NULL;\" 2>/dev/null | while IFS='|' read -r comp hex; do
                pkg=\"${{comp%%/*}}\"
                [ -z \"$pkg\" ] && continue
                out=\"{}/${{pkg}}.png\"
                if [ ! -s \"$out\" ]; then
                    hex_clean=\"${{hex#X'}}\"
                    hex_clean=\"${{hex_clean%'}}\"
                    [ -n \"$hex_clean\" ] && echo -n \"$hex_clean\" | xxd -r -p > \"$out\" 2>/dev/null
                fi
            done
            chmod 644 \"{}\"/*.png 2>/dev/null",
            db, icons_dir, icons_dir
        );
        let _ = Command::new("sh").args(["-c", &script]).spawn();
    }
}
