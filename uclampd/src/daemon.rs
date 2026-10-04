use std::fs;
use std::path::Path;
use std::process::Command;
use std::thread;
use std::time::Duration;
use crate::android;
use crate::config::{Config, CURRENT_MODE_FILE, DATA_DIR, FORCED_MODE_FILE, MODDIR, PID_FILE};
use crate::fas;
use crate::freezer;
use crate::power::{self, USB_VOLTAGE};
use crate::sysfs::{self, read_int};
use crate::tuner;

pub fn restart_daemon() {
    if let Ok(pid_str) = fs::read_to_string(PID_FILE) {
        if let Ok(pid) = pid_str.trim().parse::<i32>() {
            let _ = Command::new("kill").args(["-9", &pid.to_string()]).output();
        }
        let _ = fs::remove_file(PID_FILE);
    }

    let bin_path = format!("{}/bin/uclampd", MODDIR);
    if Path::new(&bin_path).exists() {
        let _ = Command::new(&bin_path).arg("daemon").spawn();
    } else {
        let script = format!("{}/daemon.sh", MODDIR);
        let _ = Command::new("nohup").args(["/system/bin/sh", &script]).spawn();
    }
    println!("OK");
}

pub fn run() {
    let _ = fs::create_dir_all(DATA_DIR);

    // 1. Singleton PID Check
    if let Ok(pid_str) = fs::read_to_string(PID_FILE) {
        if let Ok(old_pid) = pid_str.trim().parse::<i32>() {
            let my_pid = std::process::id() as i32;
            if old_pid != my_pid && Path::new(&format!("/proc/{}", old_pid)).exists() {
                let _ = Command::new("kill").args(["-9", &old_pid.to_string()]).output();
            }
        }
    }
    let my_pid = std::process::id();
    let _ = fs::write(PID_FILE, my_pid.to_string());
    sysfs::log(&format!("Daemon started with PID {}", my_pid));

    // 2. Initial Setup
    let cfg = Config::load();
    let _ = cfg.sync_txt_lists();

    let mut current_mode = "balance".to_string();
    let _ = fs::write(CURRENT_MODE_FILE, &current_mode);
    tuner::apply_balance(None);

    loop {
        let cfg = Config::load();
        let interval = if cfg.check_interval_sec > 0 { cfg.check_interval_sec } else { 2 };

        // Check forced mode
        let mut forced = "auto".to_string();
        if let Ok(f) = fs::read_to_string(FORCED_MODE_FILE) {
            let trimmed = f.trim();
            if !trimmed.is_empty() {
                forced = trimmed.to_string();
            }
        }

        let pkg = android::get_focused_package().unwrap_or_else(|| "com.android.launcher".to_string());
        let wake = android::get_wakefulness();

        let game_apps = Config::get_game_apps();
        let battery_apps = Config::get_battery_apps();

        let target_mode = match forced.as_str() {
            "game" => "game",
            "battery" => "battery",
            "balance" => "balance",
            _ => {
                if cfg.screen_off_powersave && wake != "Awake" {
                    "battery"
                } else if game_apps.contains(&pkg) {
                    "game"
                } else if battery_apps.contains(&pkg) {
                    "battery"
                } else {
                    "balance"
                }
            }
        };

        if target_mode != current_mode {
            sysfs::log(&format!(
                "Switching mode: {} -> {} (app: {}, wake: {})",
                current_mode, target_mode, pkg, wake
            ));
            match target_mode {
                "game" => tuner::apply_game(Some(&pkg)),
                "battery" => tuner::apply_battery(Some(&pkg)),
                _ => tuner::apply_balance(Some(&pkg)),
            }
            current_mode = target_mode.to_string();
            let _ = fs::write(CURRENT_MODE_FILE, &current_mode);
        } else if current_mode == "game" {
            // Continuous game process protection while gaming
            android::protect_game_process(&pkg);

            // Ensure Encore FAS governor is running for this game process
            if cfg.encore_fas_enabled && fas::has_encore_fas() && !fas::is_fas_running() {
                fas::start_fas(&pkg, None);
            }

            // Ensure Auto Cut Charging is active if plugged in while gaming
            if cfg.game_auto_cut_charging {
                let (act, _) = power::get_autocut_status();
                if !act {
                    let _ = power::set_game_autocut(true);
                }
            }

            // Optional legacy bypass charging
            if cfg.game_bypass_charging {
                let usb_v = read_int(USB_VOLTAGE).unwrap_or(0);
                let cur_suspend = power::get_bypass_status();
                if usb_v > 4000000 && !cur_suspend {
                    let _ = power::set_bypass(true);
                }
            }

            // Ensure background apps remain frozen
            if cfg.cgroup_freezer_enabled {
                freezer::freeze_background_apps(&pkg);
            }
        }

        thread::sleep(Duration::from_secs(interval));
    }
}
