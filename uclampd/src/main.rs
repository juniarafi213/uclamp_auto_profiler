mod android;
mod config;
mod daemon;
mod fas;
mod freezer;
mod power;
mod state;
mod sysfs;
mod thermal;
mod tuner;

use std::env;
use std::process::Command;
use config::{Config, MODDIR};

fn main() {
    let args: Vec<String> = env::args().collect();
    let cmd = args.get(1).map(|s| s.as_str()).unwrap_or("status");

    match cmd {
        "daemon" => {
            daemon::run();
        }
        "game" => {
            tuner::apply_game(args.get(2).map(|s| s.as_str()));
        }
        "balance" => {
            tuner::apply_balance(args.get(2).map(|s| s.as_str()));
        }
        "battery" => {
            tuner::apply_battery(args.get(2).map(|s| s.as_str()));
        }
        "purge" => {
            android::purge_ram();
        }
        "status" | "info" => {
            state::show_status();
        }
        "get_state" => {
            println!("{}", state::get_state_json());
        }
        "get_apps" => {
            println!("{}", state::get_apps_json());
        }
        "get_info" => {
            println!("{}", state::get_info());
        }
        "set_app" => {
            let pkg = args.get(2).map(|s| s.as_str()).unwrap_or("");
            let mode = args.get(3).map(|s| s.as_str()).unwrap_or("balance");
            state::set_app_mode(pkg, mode);
        }
        "sync_config" => {
            let cfg = Config::load();
            let _ = cfg.sync_txt_lists();
            println!("OK");
        }
        "restart_daemon" => {
            daemon::restart_daemon();
        }
        "set_autocut" | "autocut" => {
            power::handle_autocut_cli(args.get(2).map(|s| s.as_str()));
        }
        "set_thermal" | "thermal" => {
            thermal::handle_thermal_cli(args.get(2).map(|s| s.as_str()));
        }
        "set_bypass" | "bypass" => {
            power::handle_bypass_cli(args.get(2).map(|s| s.as_str()));
        }
        "start_fas" => {
            let pkg = args.get(2).map(|s| s.as_str());
            let fps = args.get(3).and_then(|s| s.parse::<u32>().ok());
            fas::handle_start_fas(pkg, fps);
        }
        "stop_fas" => {
            fas::stop_fas();
        }
        "fas_status" => {
            fas::print_fas_status();
        }
        "setup_zram" => {
            let mb = args.get(2).and_then(|s| s.parse::<u64>().ok()).unwrap_or(4096);
            tuner::setup_zram(mb);
        }
        "extract_icons" => {
            android::extract_icons();
        }
        "freezer" => {
            freezer::handle_freezer_cli(args.get(2).map(|s| s.as_str()));
        }
        "monitor" | "mon" => {
            let monitor_path = format!("{}/monitor.sh", MODDIR);
            let _ = Command::new("/bin/sh")
                .arg(&monitor_path)
                .args(args.iter().skip(2))
                .status();
        }
        _ => {
            state::show_status();
        }
    }
}
