use std::fs;
use std::path::Path;
use crate::sysfs::{self, read_int, read_node, write_node};

pub const LRC_ENABLE: &str = "/sys/class/power_supply/battery/lrc_enable";
pub const LRC_SOCMAX: &str = "/sys/class/power_supply/battery/lrc_socmax";
pub const LRC_SOCMIN: &str = "/sys/class/power_supply/battery/lrc_socmin";
pub const BAT_CAPACITY: &str = "/sys/class/power_supply/battery/capacity";
pub const INPUT_SUSPEND: &str = "/sys/class/power_supply/battery/input_suspend";
pub const USB_VOLTAGE: &str = "/sys/class/power_supply/usb/voltage_now";
pub const USB_ONLINE: &str = "/sys/class/power_supply/usb/online";
pub const PC_ONLINE: &str = "/sys/class/power_supply/pc_port/online";
pub const BAT_STATUS: &str = "/sys/class/power_supply/battery/status";
pub const AUTOCUT_LEVEL_FILE: &str = "/data/adb/uclamp_profiler/game_autocut_level";

pub fn is_lrc_supported() -> bool {
    Path::new(LRC_ENABLE).exists()
}

pub fn is_bypass_supported() -> bool {
    Path::new(INPUT_SUSPEND).exists()
}

pub fn set_game_autocut(enable: bool) -> Result<(), String> {
    if !is_lrc_supported() {
        return Err("Sony LRC charging control not supported by kernel".to_string());
    }

    if enable {
        let cur_bat = read_int(BAT_CAPACITY).unwrap_or(100);
        let min_bat = if cur_bat > 3 { cur_bat - 3 } else { 1 };

        let _ = write_node(LRC_SOCMAX, &cur_bat.to_string());
        let _ = write_node(LRC_SOCMIN, &min_bat.to_string());
        let _ = write_node(LRC_ENABLE, "1");
        let _ = fs::write(AUTOCUT_LEVEL_FILE, cur_bat.to_string());

        let msg = format!(
            "Game Auto Cut Charging ACTIVATED: Locked at {}% (resume: {}% via Sony LRC)",
            cur_bat, min_bat
        );
        sysfs::log(&msg);
        println!("Game Auto Cut Charging: ACTIVATED (Locked at {}%)", cur_bat);
    } else {
        let _ = write_node(LRC_ENABLE, "0");
        let _ = fs::remove_file(AUTOCUT_LEVEL_FILE);
        sysfs::log("Game Auto Cut Charging DEACTIVATED: Normal charging resumed");
        println!("Game Auto Cut Charging: DEACTIVATED");
    }
    Ok(())
}

pub fn get_autocut_status() -> (bool, u32) {
    if !is_lrc_supported() {
        return (false, 0);
    }
    let is_active = read_node(LRC_ENABLE).unwrap_or_default() == "1";
    let level = read_int(LRC_SOCMAX).unwrap_or(0) as u32;
    (is_active, level)
}

pub fn set_bypass(enable: bool) -> Result<(), String> {
    if !is_bypass_supported() {
        return Err("Hardware input_suspend not supported by kernel".to_string());
    }

    if enable {
        let usb_v = read_int(USB_VOLTAGE).unwrap_or(0);
        let usb_online = read_int(USB_ONLINE).unwrap_or(0);
        let pc_online = read_int(PC_ONLINE).unwrap_or(0);
        let bat_st = read_node(BAT_STATUS).unwrap_or_default();

        let is_plugged = usb_v > 4000000
            || usb_online == 1
            || pc_online == 1
            || bat_st == "Charging"
            || bat_st == "Full"
            || bat_st == "Not charging";

        if is_plugged {
            let _ = write_node(INPUT_SUSPEND, "1");
            sysfs::log("Game Bypass Charging ACTIVATED (hardware input_suspend = 1)");
            println!("Game Bypass Charging: ACTIVATED");
        } else {
            println!("Game Bypass Charging: SKIPPED (USB not connected)");
        }
    } else {
        let _ = write_node(INPUT_SUSPEND, "0");
        sysfs::log("Game Bypass Charging DEACTIVATED (hardware input_suspend = 0)");
        println!("Game Bypass Charging: DEACTIVATED");
    }
    Ok(())
}

pub fn get_bypass_status() -> bool {
    read_node(INPUT_SUSPEND).unwrap_or_default() == "1"
}

pub fn is_usb_connected() -> bool {
    let usb_v = read_int(USB_VOLTAGE).unwrap_or(0);
    let usb_online = read_int(USB_ONLINE).unwrap_or(0);
    let pc_online = read_int(PC_ONLINE).unwrap_or(0);
    usb_v > 4000000 || usb_online == 1 || pc_online == 1
}

pub fn handle_autocut_cli(arg: Option<&str>) {
    match arg {
        Some("1") | Some("on") | Some("enable") => {
            let _ = set_game_autocut(true);
        }
        Some("0") | Some("off") | Some("disable") => {
            let _ = set_game_autocut(false);
        }
        Some("status") => {
            let (active, lvl) = get_autocut_status();
            if active {
                println!("Game Auto Cut Charging: ACTIVE (Locked at {}% via Sony LRC)", lvl);
            } else {
                println!("Game Auto Cut Charging: DISABLED");
            }
        }
        _ => {
            println!("Usage: uclamp autocut [on|off|status]");
        }
    }
}

pub fn handle_bypass_cli(arg: Option<&str>) {
    match arg {
        Some("1") | Some("on") | Some("enable") => {
            let _ = set_bypass(true);
        }
        Some("0") | Some("off") | Some("disable") => {
            let _ = set_bypass(false);
        }
        Some("status") => {
            let active = get_bypass_status();
            println!(
                "Bypass Charging: {}",
                if active { "ACTIVE" } else { "DISABLED" }
            );
        }
        _ => {
            println!("Usage: uclamp bypass [on|off|status]");
        }
    }
}
