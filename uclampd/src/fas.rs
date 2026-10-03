use serde::{Deserialize, Serialize};
use std::fs;
use std::path::Path;
use std::process::Command;
use crate::config::{Config, MODDIR};
use crate::sysfs;

pub const FAS_DEV_PATH: &str = "/dev/encore_fas";
pub const FAS_PID_FILE: &str = "/data/adb/uclamp_profiler/fas_governor.pid";
pub const FAS_STATE_FILE: &str = "/data/adb/uclamp_profiler/fas_state.json";

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct FasState {
    #[serde(default)]
    pub active: bool,
    #[serde(default)]
    pub pid: u32,
    #[serde(default)]
    pub pkg: String,
    #[serde(default = "default_fps")]
    pub target_fps: u32,
    #[serde(default = "default_event")]
    pub last_event: String,
    #[serde(default)]
    pub uclamp_boost: u32,
    #[serde(default)]
    pub jank_count: u32,
}

fn default_fps() -> u32 {
    60
}
fn default_event() -> String {
    "STOPPED".to_string()
}

impl Default for FasState {
    fn default() -> Self {
        Self {
            active: false,
            pid: 0,
            pkg: String::new(),
            target_fps: 60,
            last_event: "STOPPED".to_string(),
            uclamp_boost: 0,
            jank_count: 0,
        }
    }
}

pub fn has_encore_fas() -> bool {
    Path::new(FAS_DEV_PATH).exists()
}

pub fn get_fas_state() -> FasState {
    if let Ok(content) = fs::read_to_string(FAS_STATE_FILE) {
        if let Ok(st) = serde_json::from_str::<FasState>(&content) {
            return st;
        }
    }
    FasState::default()
}

pub fn is_fas_running() -> bool {
    if let Ok(content) = fs::read_to_string(FAS_PID_FILE) {
        if let Ok(pid) = content.trim().parse::<i32>() {
            if Path::new(&format!("/proc/{}", pid)).exists() {
                return true;
            }
        }
    }
    false
}

pub fn stop_fas() {
    let bin_path = format!("{}/bin/fas_governor", MODDIR);
    if Path::new(&bin_path).exists() {
        let _ = Command::new(&bin_path).arg("stop").output();
    }
    if let Ok(content) = fs::read_to_string(FAS_PID_FILE) {
        if let Ok(pid) = content.trim().parse::<i32>() {
            let _ = Command::new("kill").args(["-15", &pid.to_string()]).output();
        }
        let _ = fs::remove_file(FAS_PID_FILE);
    }
    sysfs::log("Encore FAS governor stopped");
}

pub fn start_fas(pkg: &str, target_fps_opt: Option<u32>) {
    if !has_encore_fas() {
        return;
    }
    let bin_path = format!("{}/bin/fas_governor", MODDIR);
    if !Path::new(&bin_path).exists() {
        return;
    }

    let target_fps = target_fps_opt.unwrap_or_else(|| {
        let cfg = Config::load();
        cfg.fas_target_fps
    });

    // Find main PID of pkg
    let mut target_pid: Option<u32> = None;
    if let Ok(entries) = fs::read_dir("/proc") {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                if let Ok(cmdline) = fs::read_to_string(path.join("cmdline")) {
                    let cmd = cmdline.trim_matches('\0');
                    if cmd == pkg || cmd.starts_with(&format!("{}:", pkg)) {
                        if let Some(pid_str) = path.file_name().and_then(|n| n.to_str()) {
                            if let Ok(p) = pid_str.parse::<u32>() {
                                target_pid = Some(p);
                                break;
                            }
                        }
                    }
                }
            }
        }
    }

    let pid = match target_pid {
        Some(p) => p,
        None => {
            sysfs::log(&format!(
                "Encore FAS: Process for {} not running yet, waiting for daemon attach",
                pkg
            ));
            return;
        }
    };

    // Check if already active for this PID
    if is_fas_running() {
        let state = get_fas_state();
        if state.pid == pid {
            sysfs::log(&format!(
                "Encore FAS already running on PID {} ({})",
                pid, pkg
            ));
            return;
        }
        stop_fas();
    }

    sysfs::log(&format!(
        "Starting Encore FAS governor on PID {} ({}) @ {}fps",
        pid, pkg, target_fps
    ));

    let _ = Command::new(&bin_path)
        .args(["start", &pid.to_string(), &target_fps.to_string(), pkg])
        .spawn();
}

pub fn handle_start_fas(pkg_opt: Option<&str>, fps_opt: Option<u32>) {
    if let Some(pkg) = pkg_opt {
        start_fas(pkg, fps_opt);
    } else {
        println!("Usage: uclamp start_fas <pkg> [fps]");
    }
}

pub fn print_fas_status() {
    let st = get_fas_state();
    println!("{}", serde_json::to_string(&st).unwrap_or_default());
}
