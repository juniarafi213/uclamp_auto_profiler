use serde::{Deserialize, Serialize};
use std::fs::{self, File};
use std::io::{BufRead, BufReader, Write};
use std::path::Path;

pub const DATA_DIR: &str = "/data/adb/uclamp_profiler";
pub const MODDIR: &str = "/data/adb/modules/uclamp_auto_profiler";
pub const CONFIG_FILE: &str = "/data/adb/uclamp_profiler/config.json";
pub const DEFAULT_CONFIG_FILE: &str = "/data/adb/modules/uclamp_auto_profiler/default_config.json";
pub const GAME_APPS_FILE: &str = "/data/adb/uclamp_profiler/game_apps.txt";
pub const BATTERY_APPS_FILE: &str = "/data/adb/uclamp_profiler/battery_apps.txt";
pub const FORCED_MODE_FILE: &str = "/data/adb/uclamp_profiler/forced_mode";
pub const CURRENT_MODE_FILE: &str = "/data/adb/uclamp_profiler/current_mode";
pub const PID_FILE: &str = "/data/adb/uclamp_profiler/daemon.pid";

fn default_true() -> bool {
    true
}
fn default_false() -> bool {
    false
}
fn default_interval() -> u64 {
    2
}
fn default_forced() -> String {
    "auto".to_string()
}
fn default_charging_limit() -> u32 {
    80
}
fn default_battery_level() -> u32 {
    20
}
fn default_freezer_whitelist() -> Vec<String> {
    vec![
        "bellavita.toast".to_string(),
        "com.rifsxd.ksunext".to_string(),
        "com.android.inputmethod.latin".to_string(),
        "com.google.android.inputmethod.latin".to_string(),
        "com.android.launcher3".to_string(),
        "pulse".to_string(),
    ]
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct Config {
    #[serde(default = "default_true")]
    pub auto_mode: bool,

    #[serde(default = "default_forced")]
    pub forced_mode: String,

    #[serde(default = "default_interval")]
    pub check_interval_sec: u64,

    #[serde(default = "default_true")]
    pub screen_off_powersave: bool,

    #[serde(default = "default_true")]
    pub toast_notifications: bool,

    #[serde(default = "default_false")]
    pub game_bypass_charging: bool,

    #[serde(default = "default_true", alias = "auto_cut_charging")]
    pub game_auto_cut_charging: bool,

    #[serde(default = "default_charging_limit")]
    pub charging_limit_level: u32,

    #[serde(default = "default_true")]
    pub disable_thermal_throttling: bool,

    #[serde(default = "default_true")]
    pub encore_fas_enabled: bool,

    #[serde(default)]
    pub fas_target_fps: u32,

    #[serde(default = "default_true")]
    pub battery_saver_trigger: bool,

    #[serde(default = "default_battery_level")]
    pub battery_saver_level: u32,

    #[serde(default)]
    pub game_apps: Vec<String>,

    #[serde(default)]
    pub battery_apps: Vec<String>,

    #[serde(default = "default_true")]
    pub cgroup_freezer_enabled: bool,

    #[serde(default = "default_freezer_whitelist")]
    pub freezer_whitelist: Vec<String>,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            auto_mode: true,
            forced_mode: "auto".to_string(),
            check_interval_sec: 2,
            screen_off_powersave: true,
            toast_notifications: true,
            game_bypass_charging: false,
            game_auto_cut_charging: true,
            charging_limit_level: 80,
            disable_thermal_throttling: true,
            encore_fas_enabled: true,
            fas_target_fps: 0,
            battery_saver_trigger: true,
            battery_saver_level: 20,
            game_apps: vec![
                "com.miHoYo.GenshinImpact".to_string(),
                "com.cognosphere.GenshinImpact".to_string(),
                "com.HoYoverse.hkrpgoversea".to_string(),
                "com.miHoYo.hkrpg".to_string(),
                "com.HoYoverse.Nap".to_string(),
                "com.kurogame.wutheringwaves.global".to_string(),
                "com.mobile.legends".to_string(),
                "com.dts.freefireth".to_string(),
                "com.tencent.ig".to_string(),
                "com.pubg.krmobile".to_string(),
                "com.activision.callofduty.shooter".to_string(),
            ],
            battery_apps: vec![
                "com.google.android.apps.books".to_string(),
                "com.amazon.kindle".to_string(),
            ],
            cgroup_freezer_enabled: true,
            freezer_whitelist: default_freezer_whitelist(),
        }
    }
}

impl Config {
    pub fn load() -> Self {
        let _ = fs::create_dir_all(DATA_DIR);
        if let Ok(content) = fs::read_to_string(CONFIG_FILE) {
            if let Ok(cfg) = serde_json::from_str::<Config>(&content) {
                return cfg;
            }
        }
        if let Ok(content) = fs::read_to_string(DEFAULT_CONFIG_FILE) {
            if let Ok(cfg) = serde_json::from_str::<Config>(&content) {
                let _ = cfg.save();
                return cfg;
            }
        }
        let cfg = Config::default();
        let _ = cfg.save();
        cfg
    }

    pub fn save(&self) -> std::io::Result<()> {
        let _ = fs::create_dir_all(DATA_DIR);
        let json = serde_json::to_string_pretty(self).unwrap_or_default();
        let mut file = fs::OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(true)
            .open(CONFIG_FILE)?;
        file.write_all(json.as_bytes())?;
        file.flush()?;
        let _ = self.sync_txt_lists();
        Ok(())
    }

    pub fn sync_txt_lists(&self) -> std::io::Result<()> {
        let _ = fs::create_dir_all(DATA_DIR);
        let mut gfile = fs::File::create(GAME_APPS_FILE)?;
        for app in &self.game_apps {
            writeln!(gfile, "{}", app.trim())?;
        }

        let mut bfile = fs::File::create(BATTERY_APPS_FILE)?;
        for app in &self.battery_apps {
            writeln!(bfile, "{}", app.trim())?;
        }
        Ok(())
    }

    pub fn read_app_list(path: &str) -> Vec<String> {
        let mut list = Vec::new();
        if let Ok(file) = File::open(path) {
            let reader = BufReader::new(file);
            for line in reader.lines().flatten() {
                let trimmed = line.trim();
                if !trimmed.is_empty() && !trimmed.starts_with('#') {
                    list.push(trimmed.to_string());
                }
            }
        }
        list
    }

    pub fn get_game_apps() -> Vec<String> {
        if Path::new(GAME_APPS_FILE).exists() {
            Self::read_app_list(GAME_APPS_FILE)
        } else {
            let cfg = Self::load();
            let _ = cfg.sync_txt_lists();
            cfg.game_apps
        }
    }

    pub fn get_battery_apps() -> Vec<String> {
        if Path::new(BATTERY_APPS_FILE).exists() {
            Self::read_app_list(BATTERY_APPS_FILE)
        } else {
            let cfg = Self::load();
            let _ = cfg.sync_txt_lists();
            cfg.battery_apps
        }
    }
}
