use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::Path;
use std::time::SystemTime;

pub const LOG_FILE: &str = "/data/adb/uclamp_profiler/daemon.log";

pub fn log(msg: &str) {
    let now = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    // Simple timestamp formatting (epoch seconds fallback or system date)
    let log_line = format!("[{}] {}\n", now, msg);
    if let Ok(mut f) = OpenOptions::new().create(true).append(true).open(LOG_FILE) {
        let _ = f.write_all(log_line.as_bytes());
    }
}

pub fn write_node(path: &str, value: &str) -> std::io::Result<()> {
    let mut file = OpenOptions::new().write(true).truncate(true).open(path)?;
    file.write_all(value.as_bytes())?;
    file.flush()
}

pub fn read_node(path: &str) -> std::io::Result<String> {
    let content = fs::read_to_string(path)?;
    Ok(content.trim().to_string())
}

pub fn read_int(path: &str) -> Option<i64> {
    read_node(path).ok()?.parse::<i64>().ok()
}

#[allow(dead_code)]
pub fn read_u64(path: &str) -> Option<u64> {
    read_node(path).ok()?.parse::<u64>().ok()
}

#[allow(dead_code)]
pub fn node_exists(path: &str) -> bool {
    Path::new(path).exists()
}

pub fn set_sysctl(key: &str, value: &str) {
    let path = format!("/proc/sys/{}", key.replace('.', "/"));
    let _ = write_node(&path, value);
}

pub fn set_uclamp(group: &str, min: &str, max: &str, boost: &str, ls: &str) {
    let base = format!("/dev/cpuset/{}", group);
    if !Path::new(&base).exists() {
        return;
    }
    let _ = write_node(&format!("{}/uclamp.max", base), max);
    let _ = write_node(&format!("{}/uclamp.min", base), min);
    let _ = write_node(&format!("{}/uclamp.boosted", base), boost);
    let _ = write_node(&format!("{}/uclamp.latency_sensitive", base), ls);
}
