use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{BufRead, BufReader};
use std::path::Path;
use crate::config::Config;
use crate::sysfs::{self, read_node, write_node};

pub const CGROUP_APPS_DIR: &str = "/sys/fs/cgroup/apps";
pub const PACKAGES_LIST_FILE: &str = "/data/system/packages.list";

pub fn is_freezer_supported() -> bool {
    Path::new(&format!("{}/cgroup.freeze", CGROUP_APPS_DIR)).exists()
        || Path::new(CGROUP_APPS_DIR).exists()
}

pub fn get_uid_package_map() -> HashMap<u32, Vec<String>> {
    let mut map: HashMap<u32, Vec<String>> = HashMap::new();
    if let Ok(file) = File::open(PACKAGES_LIST_FILE) {
        let reader = BufReader::new(file);
        for line in reader.lines().flatten() {
            let parts: Vec<&str> = line.split_whitespace().collect();
            if parts.len() >= 2 {
                let pkg = parts[0].to_string();
                if let Ok(uid) = parts[1].parse::<u32>() {
                    map.entry(uid).or_default().push(pkg);
                }
            }
        }
    }
    map
}

pub fn get_uid_for_package(target_pkg: &str) -> Option<u32> {
    if let Ok(file) = File::open(PACKAGES_LIST_FILE) {
        let reader = BufReader::new(file);
        for line in reader.lines().flatten() {
            let parts: Vec<&str> = line.split_whitespace().collect();
            if parts.len() >= 2 && parts[0] == target_pkg {
                return parts[1].parse::<u32>().ok();
            }
        }
    }
    None
}

pub fn is_whitelisted_uid(uid: u32, game_uid: Option<u32>, map: &HashMap<u32, Vec<String>>, cfg: &Config) -> bool {
    // 1. Never freeze system UIDs
    if uid < 10000 {
        return true;
    }

    // 2. Never freeze active game
    if let Some(guid) = game_uid {
        if uid == guid {
            return true;
        }
    }

    // 3. Check packages for this UID
    if let Some(pkgs) = map.get(&uid) {
        for pkg in pkgs {
            let pkg_lower = pkg.to_lowercase();
            // Whitelisted in config (exact match or substring)
            if cfg.freezer_whitelist.iter().any(|w| {
                let w_lower = w.to_lowercase();
                pkg_lower == w_lower || pkg_lower.contains(&w_lower)
            }) {
                return true;
            }
            // Essential system UI, launchers (including Pulse), and Input methods (Keyboard)
            if pkg_lower.contains("launcher")
                || pkg_lower.contains("pulse")
                || pkg.starts_with("com.android.inputmethod")
                || pkg.starts_with("com.google.android.inputmethod")
                || pkg == "com.android.systemui"
                || pkg == "bellavita.toast"
                || pkg == "com.rifsxd.ksunext"
            {
                return true;
            }
        }
    }

    false
}

pub fn freeze_background_apps(game_pkg: &str) -> usize {
    if !is_freezer_supported() {
        return 0;
    }

    let cfg = Config::load();
    if !cfg.cgroup_freezer_enabled {
        return 0;
    }

    let game_uid = get_uid_for_package(game_pkg);
    let map = get_uid_package_map();
    let mut frozen_count = 0;

    if let Ok(entries) = fs::read_dir(CGROUP_APPS_DIR) {
        for entry in entries.flatten() {
            let path = entry.path();
            if !path.is_dir() {
                continue;
            }

            let file_name = match path.file_name().and_then(|n| n.to_str()) {
                Some(s) => s,
                None => continue,
            };

            if !file_name.starts_with("uid_") {
                continue;
            }

            let uid_str = &file_name[4..];
            let uid = match uid_str.parse::<u32>() {
                Ok(u) => u,
                Err(_) => continue,
            };

            if is_whitelisted_uid(uid, game_uid, &map, &cfg) {
                continue;
            }

            let freeze_file = path.join("cgroup.freeze");
            if freeze_file.exists() {
                let cur_state = read_node(freeze_file.to_str().unwrap_or("")).unwrap_or_default();
                if cur_state != "1" {
                    let _ = write_node(freeze_file.to_str().unwrap_or(""), "1");
                    frozen_count += 1;
                }
            }
        }
    }

    if frozen_count > 0 {
        let msg = format!(
            "Cgroup Freezer: Froze {} background app(s) for {}",
            frozen_count, game_pkg
        );
        sysfs::log(&msg);
        println!("{}", msg);
    }

    frozen_count
}

pub fn unfreeze_all_apps() -> usize {
    if !is_freezer_supported() {
        return 0;
    }

    let mut unfrozen_count = 0;
    if let Ok(entries) = fs::read_dir(CGROUP_APPS_DIR) {
        for entry in entries.flatten() {
            let path = entry.path();
            if !path.is_dir() {
                continue;
            }

            let file_name = match path.file_name().and_then(|n| n.to_str()) {
                Some(s) => s,
                None => continue,
            };

            if !file_name.starts_with("uid_") {
                continue;
            }

            let freeze_file = path.join("cgroup.freeze");
            if freeze_file.exists() {
                let cur_state = read_node(freeze_file.to_str().unwrap_or("")).unwrap_or_default();
                if cur_state == "1" {
                    let _ = write_node(freeze_file.to_str().unwrap_or(""), "0");
                    unfrozen_count += 1;
                }
            }
        }
    }

    if unfrozen_count > 0 {
        let msg = format!("Cgroup Freezer: Unfroze {} background app(s)", unfrozen_count);
        sysfs::log(&msg);
        println!("{}", msg);
    }

    unfrozen_count
}

pub fn get_frozen_count() -> usize {
    if !is_freezer_supported() {
        return 0;
    }
    let mut count = 0;
    if let Ok(entries) = fs::read_dir(CGROUP_APPS_DIR) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                let freeze_file = path.join("cgroup.freeze");
                if freeze_file.exists() {
                    if let Ok(st) = read_node(freeze_file.to_str().unwrap_or("")) {
                        if st == "1" {
                            count += 1;
                        }
                    }
                }
            }
        }
    }
    count
}

pub fn get_frozen_packages() -> Vec<String> {
    let mut pkgs = Vec::new();
    if !is_freezer_supported() {
        return pkgs;
    }
    let map = get_uid_package_map();
    if let Ok(entries) = fs::read_dir(CGROUP_APPS_DIR) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                let freeze_file = path.join("cgroup.freeze");
                if freeze_file.exists() {
                    if let Ok(st) = read_node(freeze_file.to_str().unwrap_or("")) {
                        if st == "1" {
                            if let Some(fname) = path.file_name().and_then(|n| n.to_str()) {
                                if fname.starts_with("uid_") {
                                    if let Ok(uid) = fname[4..].parse::<u32>() {
                                        if let Some(plist) = map.get(&uid) {
                                            for p in plist {
                                                pkgs.push(p.clone());
                                            }
                                        } else {
                                            pkgs.push(format!("UID_{}", uid));
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    pkgs
}

pub fn handle_freezer_cli(arg: Option<&str>) {
    match arg {
        Some("unfreeze") => {
            unfreeze_all_apps();
        }
        Some("freeze") => {
            freeze_background_apps("");
        }
        Some("status") => {
            let count = get_frozen_count();
            let pkgs = get_frozen_packages();
            println!("Cgroup Freezer Status: {} app(s) frozen", count);
            for p in pkgs {
                println!(" - {}", p);
            }
        }
        _ => {
            println!("Usage: uclamp freezer [status|freeze|unfreeze]");
        }
    }
}
