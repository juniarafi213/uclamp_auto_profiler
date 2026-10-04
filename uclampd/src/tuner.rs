use std::fs;
use std::path::Path;
use std::process::Command;
use crate::android;
use crate::config::{Config, CURRENT_MODE_FILE};
use crate::fas;
use crate::power;
use crate::sysfs::{self, read_int, read_node, set_sysctl, set_uclamp, write_node};
use crate::thermal;

pub const SYS_CPU: &str = "/sys/devices/system/cpu";
pub const SYS_GPU: &str = "/sys/class/kgsl/kgsl-3d0";
pub const SYS_SDA: &str = "/sys/block/sda";
pub const SYS_ZRAM: &str = "/sys/block/zram0";

pub fn setup_zram(target_mb: u64) {
    let current_bytes = read_int(&format!("{}/disksize", SYS_ZRAM)).unwrap_or(0);
    let current_mb = (current_bytes / 1048576) as u64;
    let current_alg = read_node(&format!("{}/comp_algorithm", SYS_ZRAM)).unwrap_or_default();
    let is_zstd = current_alg.contains("[zstd]");
    let swaps = fs::read_to_string("/proc/swaps").unwrap_or_default();
    let swap_active = swaps.contains("zram0");

    let min_acceptable = if target_mb > 256 { target_mb - 256 } else { target_mb };

    if current_mb >= min_acceptable && is_zstd && swap_active {
        return;
    }

    let _ = Command::new("swapoff").arg("/dev/block/zram0").output();
    let _ = write_node(&format!("{}/reset", SYS_ZRAM), "1");

    let comp_algs = read_node(&format!("{}/comp_algorithm", SYS_ZRAM)).unwrap_or_default();
    if comp_algs.contains("zstd") {
        let _ = write_node(&format!("{}/comp_algorithm", SYS_ZRAM), "zstd");
    } else {
        let _ = write_node(&format!("{}/comp_algorithm", SYS_ZRAM), "lz4");
    }

    let _ = write_node(&format!("{}/disksize", SYS_ZRAM), &format!("{}M", target_mb));
    let _ = Command::new("mkswap").arg("/dev/block/zram0").output();
    let _ = Command::new("swapon").args(["/dev/block/zram0", "-p", "32767"]).output();
}

pub fn apply_game(pkg_opt: Option<&str>) {
    let pkg = pkg_opt.unwrap_or("");

    // 1. CPU CASS & UCLAMP
    set_sysctl("kernel.sched_util_clamp_min_rt_default", "160");
    set_sysctl("kernel.sched_util_clamp_min", "128");
    set_uclamp("top-app", "35", "max", "1", "1");
    set_uclamp("foreground", "20", "60", "0", "0");
    set_uclamp("background", "0", "20", "0", "0");
    set_uclamp("system-background", "5", "30", "0", "0");
    set_uclamp("restricted", "0", "20", "0", "0");

    // 2. Schedutil Governors (Instant Ramp & Anti-Stutter)
    let _ = write_node(&format!("{}/cpufreq/policy0/schedutil/up_rate_limit_us", SYS_CPU), "0");
    let _ = write_node(&format!("{}/cpufreq/policy0/schedutil/down_rate_limit_us", SYS_CPU), "40000");
    let _ = write_node(&format!("{}/cpufreq/policy0/schedutil/hispeed_load", SYS_CPU), "85");
    let _ = write_node(&format!("{}/cpufreq/policy0/schedutil/hispeed_freq", SYS_CPU), "1516800");

    let _ = write_node(&format!("{}/cpufreq/policy4/schedutil/up_rate_limit_us", SYS_CPU), "0");
    let _ = write_node(&format!("{}/cpufreq/policy4/schedutil/down_rate_limit_us", SYS_CPU), "50000");
    let _ = write_node(&format!("{}/cpufreq/policy4/schedutil/hispeed_load", SYS_CPU), "80");
    let _ = write_node(&format!("{}/cpufreq/policy4/schedutil/hispeed_freq", SYS_CPU), "2092800");

    // 3. GPU Tuning (Adreno 630 kgsl-3d0)
    let _ = write_node(&format!("{}/min_pwrlevel", SYS_GPU), "5");
    let _ = write_node(&format!("{}/max_pwrlevel", SYS_GPU), "0");
    let _ = write_node(&format!("{}/default_pwrlevel", SYS_GPU), "4");
    let _ = write_node(&format!("{}/idle_timer", SYS_GPU), "80");

    // 4. Virtual Memory & ZRAM
    setup_zram(4096);
    set_sysctl("vm.swappiness", "100");
    set_sysctl("vm.vfs_cache_pressure", "60");
    set_sysctl("vm.min_free_kbytes", "32768");
    set_sysctl("vm.extra_free_kbytes", "32768");
    set_sysctl("vm.dirty_ratio", "15");
    set_sysctl("vm.dirty_background_ratio", "5");
    set_sysctl("vm.page-cluster", "0");
    if Path::new("/proc/sys/vm/workingset_protection").exists() {
        let _ = write_node("/proc/sys/vm/workingset_protection", "1");
        let _ = write_node("/proc/sys/vm/clean_min_ratio", "5");
        let _ = write_node("/proc/sys/vm/clean_low_ratio", "10");
    }

    // 5. LMKD Anti-Kill properties
    android::apply_lmkd_props();

    // 6. I/O Anxiety Scheduler
    let _ = write_node(&format!("{}/queue/scheduler", SYS_SDA), "anxiety");
    let _ = write_node(&format!("{}/queue/iosched/sync_ratio", SYS_SDA), "8");
    let _ = write_node(&format!("{}/queue/read_ahead_kb", SYS_SDA), "1024");

    // 7. Drop cache & protect game process with OOM -1000
    android::purge_ram();
    if !pkg.is_empty() {
        android::protect_game_process(pkg);
    }

    // 8. Power & Charging Protection
    let cfg = Config::load();
    if cfg.game_auto_cut_charging {
        let _ = power::set_game_autocut(true);
    }
    if cfg.game_bypass_charging {
        let _ = power::set_bypass(true);
    }

    // 9. Thermal Throttling Control
    if cfg.disable_thermal_throttling {
        thermal::stop_thermal_engine();
    }

    // 10. Frame Aware Scheduling (Encore FAS)
    if cfg.encore_fas_enabled && !pkg.is_empty() {
        fas::start_fas(pkg, None);
    }

    let _ = fs::write(CURRENT_MODE_FILE, "game");
    sysfs::log(&format!("Profile switched to GAME (pkg: {})", if pkg.is_empty() { "manual" } else { pkg }));
    android::show_toast_popup("Uclamp: Game Mode", "game");
    println!("Applied profile: GAME");
}

pub fn apply_balance(pkg_opt: Option<&str>) {
    let pkg = pkg_opt.unwrap_or("");

    // Deactivate game features
    let _ = power::set_game_autocut(false);
    let _ = power::set_bypass(false);
    fas::stop_fas();

    let cfg = Config::load();
    if !cfg.disable_thermal_throttling {
        thermal::start_thermal_engine();
    }

    // 1. CPU CASS & UCLAMP
    set_sysctl("kernel.sched_util_clamp_min_rt_default", "96");
    set_sysctl("kernel.sched_util_clamp_min", "128");
    set_uclamp("top-app", "20", "max", "1", "1");
    set_uclamp("foreground", "20", "50", "0", "0");
    set_uclamp("background", "0", "50", "0", "0");
    set_uclamp("system-background", "10", "50", "0", "0");
    set_uclamp("restricted", "0", "30", "0", "0");

    // 2. Schedutil Governors (Daily Smoothness)
    let _ = write_node(&format!("{}/cpufreq/policy0/schedutil/up_rate_limit_us", SYS_CPU), "500");
    let _ = write_node(&format!("{}/cpufreq/policy0/schedutil/down_rate_limit_us", SYS_CPU), "20000");
    let _ = write_node(&format!("{}/cpufreq/policy0/schedutil/hispeed_load", SYS_CPU), "90");
    let _ = write_node(&format!("{}/cpufreq/policy0/schedutil/hispeed_freq", SYS_CPU), "1132800");

    let _ = write_node(&format!("{}/cpufreq/policy4/schedutil/up_rate_limit_us", SYS_CPU), "500");
    let _ = write_node(&format!("{}/cpufreq/policy4/schedutil/down_rate_limit_us", SYS_CPU), "20000");
    let _ = write_node(&format!("{}/cpufreq/policy4/schedutil/hispeed_load", SYS_CPU), "90");
    let _ = write_node(&format!("{}/cpufreq/policy4/schedutil/hispeed_freq", SYS_CPU), "1612800");

    // 3. GPU Tuning
    let _ = write_node(&format!("{}/min_pwrlevel", SYS_GPU), "6");
    let _ = write_node(&format!("{}/max_pwrlevel", SYS_GPU), "0");
    let _ = write_node(&format!("{}/default_pwrlevel", SYS_GPU), "6");
    let _ = write_node(&format!("{}/idle_timer", SYS_GPU), "80");

    // 4. Virtual Memory & ZRAM
    setup_zram(4096);
    set_sysctl("vm.swappiness", "100");
    set_sysctl("vm.watermark_scale_factor", "15");
    set_sysctl("vm.vfs_cache_pressure", "100");
    set_sysctl("vm.dirty_ratio", "20");
    set_sysctl("vm.dirty_background_ratio", "10");
    set_sysctl("vm.page-cluster", "0");
    if Path::new("/proc/sys/vm/workingset_protection").exists() {
        let _ = write_node("/proc/sys/vm/workingset_protection", "1");
        let _ = write_node("/proc/sys/vm/clean_min_ratio", "5");
        let _ = write_node("/proc/sys/vm/clean_low_ratio", "10");
    }

    // 5. I/O Anxiety Scheduler
    let _ = write_node(&format!("{}/queue/scheduler", SYS_SDA), "anxiety");
    let _ = write_node(&format!("{}/queue/iosched/sync_ratio", SYS_SDA), "4");
    let _ = write_node(&format!("{}/queue/read_ahead_kb", SYS_SDA), "512");

    let _ = fs::write(CURRENT_MODE_FILE, "balance");
    sysfs::log(&format!("Profile switched to BALANCE (pkg: {})", if pkg.is_empty() { "manual" } else { pkg }));
    android::show_toast_popup("Uclamp: Balanced", "balance");
    println!("Applied profile: BALANCE");
}

pub fn apply_battery(pkg_opt: Option<&str>) {
    let pkg = pkg_opt.unwrap_or("");

    // Deactivate game features
    let _ = power::set_game_autocut(false);
    let _ = power::set_bypass(false);
    fas::stop_fas();

    let cfg = Config::load();
    if !cfg.disable_thermal_throttling {
        thermal::start_thermal_engine();
    }

    // 1. CPU CASS & UCLAMP
    set_sysctl("kernel.sched_util_clamp_min_rt_default", "64");
    set_sysctl("kernel.sched_util_clamp_min", "0");
    set_uclamp("top-app", "0", "80", "0", "0");
    set_uclamp("foreground", "0", "40", "0", "0");
    set_uclamp("background", "0", "20", "0", "0");
    set_uclamp("system-background", "0", "20", "0", "0");
    set_uclamp("restricted", "0", "20", "0", "0");

    // 2. Schedutil Governors (Aggressive Powersave)
    let _ = write_node(&format!("{}/cpufreq/policy0/schedutil/up_rate_limit_us", SYS_CPU), "2000");
    let _ = write_node(&format!("{}/cpufreq/policy0/schedutil/down_rate_limit_us", SYS_CPU), "5000");
    let _ = write_node(&format!("{}/cpufreq/policy0/schedutil/hispeed_load", SYS_CPU), "95");
    let _ = write_node(&format!("{}/cpufreq/policy0/schedutil/hispeed_freq", SYS_CPU), "902400");

    let _ = write_node(&format!("{}/cpufreq/policy4/schedutil/up_rate_limit_us", SYS_CPU), "3000");
    let _ = write_node(&format!("{}/cpufreq/policy4/schedutil/down_rate_limit_us", SYS_CPU), "5000");
    let _ = write_node(&format!("{}/cpufreq/policy4/schedutil/hispeed_load", SYS_CPU), "95");
    let _ = write_node(&format!("{}/cpufreq/policy4/schedutil/hispeed_freq", SYS_CPU), "1209600");

    // 3. GPU Tuning (Capped at 520 MHz)
    let _ = write_node(&format!("{}/min_pwrlevel", SYS_GPU), "6");
    let _ = write_node(&format!("{}/max_pwrlevel", SYS_GPU), "3");
    let _ = write_node(&format!("{}/default_pwrlevel", SYS_GPU), "6");
    let _ = write_node(&format!("{}/idle_timer", SYS_GPU), "40");

    // 4. Virtual Memory & ZRAM
    set_sysctl("vm.swappiness", "60");
    set_sysctl("vm.watermark_scale_factor", "10");
    set_sysctl("vm.vfs_cache_pressure", "100");

    // 5. I/O Anxiety Scheduler
    let _ = write_node(&format!("{}/queue/scheduler", SYS_SDA), "anxiety");
    let _ = write_node(&format!("{}/queue/iosched/sync_ratio", SYS_SDA), "2");
    let _ = write_node(&format!("{}/queue/read_ahead_kb", SYS_SDA), "128");

    let _ = fs::write(CURRENT_MODE_FILE, "battery");
    sysfs::log(&format!("Profile switched to BATTERY (pkg: {})", if pkg.is_empty() { "manual" } else { pkg }));
    android::show_toast_popup("Uclamp: Battery Saver", "battery");
    println!("Applied profile: BATTERY");
}
