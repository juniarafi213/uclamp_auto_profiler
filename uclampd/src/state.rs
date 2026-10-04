use serde_json::json;
use std::fs;
use std::path::Path;
use std::process::Command;
use crate::android;
use crate::config::{Config, CURRENT_MODE_FILE, PID_FILE};
use crate::fas;
use crate::power;
use crate::sysfs::{read_int, read_node};
use crate::thermal;
use crate::tuner;

pub fn get_state_json() -> serde_json::Value {
    let cur_mode = read_node(CURRENT_MODE_FILE).unwrap_or_else(|_| "balance".to_string());

    let daemon_alive = if let Ok(pid_str) = fs::read_to_string(PID_FILE) {
        if let Ok(pid) = pid_str.trim().parse::<i32>() {
            Path::new(&format!("/proc/{}", pid)).exists()
        } else {
            false
        }
    } else {
        false
    };

    let top_pkg = android::get_focused_package().unwrap_or_else(|| "None".to_string());

    // Meminfo parsing
    let mut ram_total = 3674;
    let mut ram_avail = 1000;
    if let Ok(meminfo) = fs::read_to_string("/proc/meminfo") {
        for line in meminfo.lines() {
            if line.starts_with("MemTotal:") {
                let parts: Vec<&str> = line.split_whitespace().collect();
                if parts.len() >= 2 {
                    if let Ok(kb) = parts[1].parse::<u64>() {
                        ram_total = kb / 1024;
                    }
                }
            } else if line.starts_with("MemAvailable:") {
                let parts: Vec<&str> = line.split_whitespace().collect();
                if parts.len() >= 2 {
                    if let Ok(kb) = parts[1].parse::<u64>() {
                        ram_avail = kb / 1024;
                    }
                }
            }
        }
    }
    let ram_used = if ram_total > ram_avail { ram_total - ram_avail } else { 0 };
    let ram_free = ram_avail;

    // Swap parsing
    let mut swap_total = 3583;
    let mut swap_used = 0;
    if let Ok(swaps) = fs::read_to_string("/proc/swaps") {
        for line in swaps.lines() {
            if line.contains("zram0") {
                let parts: Vec<&str> = line.split_whitespace().collect();
                if parts.len() >= 4 {
                    if let Ok(st) = parts[2].parse::<u64>() {
                        swap_total = st / 1024;
                    }
                    if let Ok(su) = parts[3].parse::<u64>() {
                        swap_used = su / 1024;
                    }
                }
            }
        }
    }

    let cpu_lit = read_int(&format!("{}/cpu0/cpufreq/scaling_cur_freq", tuner::SYS_CPU)).unwrap_or(0);
    let cpu_big = read_int(&format!("{}/cpu4/cpufreq/scaling_cur_freq", tuner::SYS_CPU)).unwrap_or(0);

    let gpu_mhz = read_int(&format!("{}/clock_mhz", tuner::SYS_GPU))
        .or_else(|| read_int(&format!("{}/gpuclk", tuner::SYS_GPU)).map(|hz| hz / 1000000))
        .unwrap_or(0);
    let gpu_pwr = read_int(&format!("{}/min_pwrlevel", tuner::SYS_GPU)).unwrap_or(6);

    let (bat_lvl, bat_st, is_chg) = android::get_battery_info();
    let usb_conn = power::is_usb_connected();
    let bypass_act = power::get_bypass_status();
    let (autocut_act, autocut_lvl) = power::get_autocut_status();
    let therm_act = thermal::is_thermal_engine_running();
    let wake = android::get_wakefulness();

    let mut swap_alg = "ZSTD".to_string();
    if let Ok(alg_str) = read_node(&format!("{}/comp_algorithm", tuner::SYS_ZRAM)) {
        if let Some(start) = alg_str.find('[') {
            if let Some(end) = alg_str.find(']') {
                if end > start {
                    swap_alg = alg_str[start + 1..end].to_uppercase();
                }
            }
        }
    }

    let has_fas = fas::has_encore_fas();
    let fas_state = fas::get_fas_state();

    json!({
        "current_mode": cur_mode,
        "daemon_alive": daemon_alive,
        "top_package": top_pkg,
        "ram_total": ram_total,
        "ram_used": ram_used,
        "ram_free": ram_free,
        "swap_total": swap_total,
        "swap_used": swap_used,
        "swap_alg": swap_alg,
        "cpu_little_mhz": cpu_lit / 1000,
        "cpu_big_mhz": cpu_big / 1000,
        "gpu_mhz": gpu_mhz,
        "gpu_pwrlevel": gpu_pwr,
        "battery_level": bat_lvl,
        "battery_status": bat_st,
        "is_charging": is_chg,
        "is_usb_connected": usb_conn,
        "bypass_active": bypass_act,
        "auto_cut_active": autocut_act,
        "auto_cut_level": autocut_lvl,
        "thermal_active": therm_act,
        "wakefulness": wake,
        "has_encore_fas": has_fas,
        "fas_active": fas_state.active,
        "fas_pid": fas_state.pid,
        "fas_pkg": fas_state.pkg,
        "fas_target_fps": fas_state.target_fps,
        "fas_last_event": fas_state.last_event,
        "fas_uclamp_boost": fas_state.uclamp_boost,
        "fas_jank_count": fas_state.jank_count
    })
}

pub fn get_apps_json() -> serde_json::Value {
    let game_apps = Config::get_game_apps();
    let battery_apps = Config::get_battery_apps();

    let mut apps = Vec::new();
    if let Ok(out) = Command::new("cmd")
        .args([
            "package",
            "query-activities",
            "--brief",
            "-a",
            "android.intent.action.MAIN",
            "-c",
            "android.intent.category.LAUNCHER",
        ])
        .output()
    {
        let stdout = String::from_utf8_lossy(&out.stdout);
        let mut packages = Vec::new();
        for line in stdout.lines() {
            if line.contains('/') {
                let pkg = line.split('/').next().unwrap_or("").trim();
                if !pkg.is_empty() && !packages.contains(&pkg.to_string()) {
                    packages.push(pkg.to_string());
                }
            }
        }
        packages.sort();

        for pkg in packages {
            let mode = if game_apps.contains(&pkg) {
                "game"
            } else if battery_apps.contains(&pkg) {
                "battery"
            } else {
                "balance"
            };

            let label = match pkg.as_str() {
                "com.miHoYo.GenshinImpact" | "com.cognosphere.GenshinImpact" => "Genshin Impact".to_string(),
                "com.franco.kernel" => "Franco Kernel Manager".to_string(),
                "tw.nekomimi.nekogram" => "Nekogram".to_string(),
                "com.rifsxd.ksunext" => "KernelSU Next".to_string(),
                "flar2.devcheck" => "DevCheck".to_string(),
                "com.android.chrome" => "Chrome".to_string(),
                "com.google.android.apps.messaging" => "Messages".to_string(),
                "com.google.android.dialer" => "Phone".to_string(),
                "com.google.android.contacts" => "Contacts".to_string(),
                "com.google.android.calculator" => "Calculator".to_string(),
                "com.google.android.calendar" => "Calendar".to_string(),
                "com.google.android.deskclock" => "Clock".to_string(),
                "com.android.settings" => "Settings".to_string(),
                "org.lineageos.aperture" => "Camera".to_string(),
                "com.shinkai.wallpapers" => "Wallpapers".to_string(),
                "com.mobile.legends" => "Mobile Legends".to_string(),
                s if s.starts_with("com.kurogame.wutheringwaves") => "Wuthering Waves".to_string(),
                s if s.starts_with("com.HoYoverse.hkrpg") || s.starts_with("com.miHoYo.hkrpg") => "Honkai: Star Rail".to_string(),
                s if s.starts_with("com.HoYoverse.Nap") => "Zenless Zone Zero".to_string(),
                "com.dts.freefireth" => "Free Fire".to_string(),
                "com.tencent.ig" | "com.pubg.krmobile" => "PUBG Mobile".to_string(),
                "com.activision.callofduty.shooter" => "Call of Duty Mobile".to_string(),
                _ => {
                    let last = pkg.split('.').last().unwrap_or(&pkg);
                    let mut chars = last.chars();
                    match chars.next() {
                        None => String::new(),
                        Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
                    }
                }
            };

            apps.push(json!({
                "pkg": pkg,
                "label": label,
                "mode": mode
            }));
        }
    }

    json!(apps)
}

pub fn get_info() -> serde_json::Value {
    let state = get_state_json();
    let config = Config::load();
    let apps = get_apps_json();

    json!({
        "state": state,
        "config": config,
        "apps": apps
    })
}

pub fn set_app_mode(pkg: &str, mode: &str) {
    if pkg.is_empty() {
        return;
    }
    let mut cfg = Config::load();
    cfg.game_apps.retain(|p| p != pkg);
    cfg.battery_apps.retain(|p| p != pkg);

    if mode == "game" {
        cfg.game_apps.push(pkg.to_string());
    } else if mode == "battery" {
        cfg.battery_apps.push(pkg.to_string());
    }
    let _ = cfg.save();

    // Trigger immediate profile switch if currently focused
    if let Some(top) = android::get_focused_package() {
        if top == pkg {
            match mode {
                "game" => tuner::apply_game(Some(pkg)),
                "battery" => tuner::apply_battery(Some(pkg)),
                _ => tuner::apply_balance(Some(pkg)),
            }
        }
    }
    println!("OK");
}

pub fn show_status() {
    let state = get_state_json();
    println!("==========================================================");
    println!("         UCLAMP AUTO PROFILER STATUS (SDM845)             ");
    println!("==========================================================");

    let cur_mode = state["current_mode"].as_str().unwrap_or("balance");
    let daemon_alive = state["daemon_alive"].as_bool().unwrap_or(false);
    let top_pkg = state["top_package"].as_str().unwrap_or("None");

    println!("[-] Profiler State:");
    println!(
        "    Daemon Status  : {}",
        if daemon_alive { "ACTIVE" } else { "INACTIVE" }
    );
    println!("    Active Mode    : {}", cur_mode);
    println!("    Top App        : {}", top_pkg);
    println!();

    let ram_total = state["ram_total"].as_u64().unwrap_or(0);
    let ram_used = state["ram_used"].as_u64().unwrap_or(0);
    let ram_free = state["ram_free"].as_u64().unwrap_or(0);
    let swap_total = state["swap_total"].as_u64().unwrap_or(0);
    let swap_used = state["swap_used"].as_u64().unwrap_or(0);
    println!("[-] Memory & ZRAM:");
    println!(
        "    Physical RAM   : {} MB used / {} MB total (Avail: {} MB)",
        ram_used, ram_total, ram_free
    );
    println!(
        "    ZRAM Swap      : {} MB used / {} MB total",
        swap_used, swap_total
    );
    println!();

    let cpu_lit = state["cpu_little_mhz"].as_u64().unwrap_or(0);
    let cpu_big = state["cpu_big_mhz"].as_u64().unwrap_or(0);
    let gpu_clk = state["gpu_mhz"].as_u64().unwrap_or(0);
    let gpu_pwr = state["gpu_pwrlevel"].as_u64().unwrap_or(6);
    println!("[-] Hardware Clocks:");
    println!("    CPU Little     : {} MHz", cpu_lit);
    println!("    CPU Big        : {} MHz", cpu_big);
    println!("    GPU Clock      : {} MHz (pwrlevel floor: {})", gpu_clk, gpu_pwr);
    println!();

    let u_min = read_node("/dev/cpuset/top-app/uclamp.min").unwrap_or_default();
    let u_max = read_node("/dev/cpuset/top-app/uclamp.max").unwrap_or_default();
    let u_bst = read_node("/dev/cpuset/top-app/uclamp.boosted").unwrap_or_default();
    let u_ls = read_node("/dev/cpuset/top-app/uclamp.latency_sensitive").unwrap_or_default();
    println!("[-] UCLAMP Top-App :");
    println!(
        "    min: {}  max: {}  boost: {}  ls: {}",
        u_min, u_max, u_bst, u_ls
    );
    println!();

    let autocut_act = state["auto_cut_active"].as_bool().unwrap_or(false);
    let autocut_lvl = state["auto_cut_level"].as_u64().unwrap_or(0);
    let bypass_act = state["bypass_active"].as_bool().unwrap_or(false);
    let bat_lvl = state["battery_level"].as_u64().unwrap_or(0);

    println!("[-] Power & Battery:");
    if autocut_act {
        println!("    Auto Cut Limit : ACTIVE (🛡️ Stopped at {}% via Sony LRC)", autocut_lvl);
    } else {
        println!("    Auto Cut Limit : DISABLED");
    }
    if bypass_act {
        println!("    Bypass Charging: ACTIVE (⚡ Hardware Direct Power)");
    } else {
        println!("    Bypass Charging: DISABLED");
    }
    println!("    Battery Level  : {}%", bat_lvl);
    println!();

    let has_fas = state["has_encore_fas"].as_bool().unwrap_or(false);
    let fas_act = state["fas_active"].as_bool().unwrap_or(false);
    println!("[-] Frame-Aware Scheduling (Encore FAS):");
    if !has_fas {
        println!("    Encore FAS     : NOT SUPPORTED (no /dev/encore_fas in kernel)");
    } else if fas_act {
        let f_pid = state["fas_pid"].as_u64().unwrap_or(0);
        let f_pkg = state["fas_pkg"].as_str().unwrap_or("");
        let f_fps = state["fas_target_fps"].as_u64().unwrap_or(60);
        let f_ev = state["fas_last_event"].as_str().unwrap_or("");
        let f_bst = state["fas_uclamp_boost"].as_u64().unwrap_or(0);
        let f_jk = state["fas_jank_count"].as_u64().unwrap_or(0);
        println!(
            "    Encore FAS     : ACTIVE (PID: {} [{}], Target: {} FPS, Event: {}, Boost: {}, Drops: {})",
            f_pid, f_pkg, f_fps, f_ev, f_bst, f_jk
        );
    } else {
        println!("    Encore FAS     : STANDBY (/dev/encore_fas ready)");
    }
    println!();

    let therm_act = state["thermal_active"].as_bool().unwrap_or(true);
    println!("[-] Thermal Management:");
    if therm_act {
        println!("    Thermal Engine : ENABLED (thermal-engine active)");
    } else {
        println!("    Thermal Engine : DISABLED (⚡ Unthrottled full performance)");
    }
    println!("==========================================================");
}
