use std::fs;
use std::process::Command;
use crate::config::Config;
use crate::sysfs;

pub fn is_thermal_engine_running() -> bool {
    if let Ok(out) = Command::new("getprop")
        .arg("init.svc.thermal-engine")
        .output()
    {
        let st = String::from_utf8_lossy(&out.stdout).trim().to_string();
        if st == "running" {
            return true;
        }
    }

    // Check /proc for thermal-engine
    if let Ok(entries) = fs::read_dir("/proc") {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                if let Ok(comm) = fs::read_to_string(path.join("comm")) {
                    if comm.trim() == "thermal-engine" {
                        return true;
                    }
                }
            }
        }
    }
    false
}

pub fn stop_thermal_engine() {
    let _ = Command::new("stop").arg("thermal-engine").status();
    sysfs::log("Thermal Throttling DISABLED (thermal-engine stopped)");
}

pub fn start_thermal_engine() {
    let _ = Command::new("start").arg("thermal-engine").status();
    sysfs::log("Thermal Throttling ENABLED (thermal-engine started)");
}

pub fn set_thermal(enable: bool, update_config: bool) {
    if enable {
        start_thermal_engine();
        println!("Thermal Throttling: ENABLED");
        if update_config {
            let mut cfg = Config::load();
            cfg.disable_thermal_throttling = false;
            let _ = cfg.save();
        }
    } else {
        stop_thermal_engine();
        println!("Thermal Throttling: DISABLED");
        if update_config {
            let mut cfg = Config::load();
            cfg.disable_thermal_throttling = true;
            let _ = cfg.save();
        }
    }
}

pub fn handle_thermal_cli(arg: Option<&str>) {
    match arg {
        Some("0") | Some("off") | Some("disable") => {
            set_thermal(false, true);
        }
        Some("1") | Some("on") | Some("enable") => {
            set_thermal(true, true);
        }
        Some("status") => {
            let running = is_thermal_engine_running();
            if running {
                println!("Thermal Throttling: ENABLED (thermal-engine active)");
            } else {
                println!("Thermal Throttling: DISABLED (thermal-engine stopped)");
            }
        }
        _ => {
            println!("Usage: uclamp thermal [on|off|status]");
        }
    }
}
