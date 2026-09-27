# UCLAMP Auto Profiler & Dynamic Tuner

[![KernelSU Next](https://img.shields.io/badge/KernelSU%20Next-Compatible-brightgreen.svg)](https://github.com/rifsxd/KernelSU-Next)
[![Platform](https://img.shields.io/badge/Platform-Qualcomm%20SDM845%20(Tama)-blue.svg)]()
[![Android](https://img.shields.io/badge/Android-14%20%2F%2015%20%2F%2016-orange.svg)]()
[![License: GPL-3.0](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

An autonomous hardware profiler and memory manager designed for **Sony Xperia SDM845 (Tama: XZ2 / XZ2C / XZ3)** running custom kernels with **CASS scheduler, UCLAMP, Anxiety I/O, le9 workingset protection, and kcompressd ZRAM**.

Includes a fully responsive, self-contained **WebUI** inside **KernelSU Next** with an interactive App Profiler Toggle Matrix.

---

## 🌟 Key Features

- 🤖 **Autonomous Profiler Daemon**:
  - Dynamically detects the active foreground app via low-overhead system queries (~30ms, battery efficient).
  - Automatically switches between **Game Mode**, **Daily Balanced**, and **Battery Saver**.
  - Monitors screen wakefulness (`Awake` / `Dozing` / `Asleep`) to drop hardware clocks when the phone is locked.
  - Automatically triggers battery endurance mode when battery falls below threshold (<= 20%).

- 🎮 **Game Mode (Max Performance & RAM Protection)**:
  - Purges caches (`drop_caches`) on launch to free up to 1.8 GB of physical RAM.
  - Grants game processes immunity from Android LMKD (`oom_score_adj = -900`).
  - Locks `top-app` cpuset with high minimum UCLAMP boost (`uclamp.min = 35`, `boosted = 1`, `latency_sensitive = 1`).
  - Sets schedutil CPU up-rate to 0µs (instant frequency spike) and holds down-rate against micro-stuttering.
  - Elevates Adreno 630 GPU clock floor to 342 MHz / 414 MHz (prevents frame drops during combat).
  - Pushes idle system background pages to 3.5 GB LZ4 ZRAM (`swappiness = 160`).

- 📱 **Interactive WebUI (KernelSU Next)**:
  - 100% self-contained (HTML5/CSS/JavaScript), zero internet dependencies.
  - Live hardware telemetry dashboard: Physical RAM, ZRAM swap, CPU Little/Big GHz, Adreno 630 MHz, and Battery %.
  - **App Profiler Toggle Matrix**: View all installed apps and toggle their profiles between `🎮 Game`, `⚖️ Daily`, and `🔋 Battery` with a single tap.
  - Instant search and category filter tabs (`All`, `Game`, `Daily`, `Battery`).
  - Manual mode overrides (`Auto`, `Force Game`, `Force Daily`, `Force Battery`).
  - Quick action buttons to drop RAM caches or restart the daemon.

---

## 📊 Hardware Tuning Matrix (SDM845)

| Subsystem / Node | 🎮 Game Mode | ⚖️ Daily Balanced | 🔋 Battery Saver |
|---|---|---|---|
| **UCLAMP `top-app`** | `min: 35` \| `max: max` \| `boost: 1` \| `ls: 1` | `min: 20` \| `max: max` \| `boost: 1` \| `ls: 1` | `min: 0` \| `max: 80` \| `boost: 0` \| `ls: 0` |
| **UCLAMP `background`** | Clamped `max: 20` | `max: 50` | `max: 20` |
| **Schedutil CPU (Little)** | `up: 0µs` \| `down: 40ms` \| `hispeed: 1.51 GHz` | `up: 500µs` \| `down: 20ms` \| `hispeed: 1.13 GHz` | `up: 2ms` \| `down: 5ms` \| `hispeed: 0.90 GHz` |
| **Schedutil CPU (Big)** | `up: 0µs` \| `down: 50ms` \| `hispeed: 2.09 GHz` | `up: 500µs` \| `down: 20ms` \| `hispeed: 1.61 GHz` | `up: 3ms` \| `down: 5ms` \| `hispeed: 1.20 GHz` |
| **GPU Adreno 630** | `min_pwr: 5 (342 MHz)` \| `max: 710 MHz` | `257 MHz - 710 MHz` | `max_pwr: 3 (Capped at 520 MHz)` |
| **Virtual Memory** | `swappiness = 160` \| `watermark = 30` | `swappiness = 100` \| `watermark = 15` | `swappiness = 60` \| `watermark = 10` |
| **I/O Anxiety (`sda`)** | `sync_ratio = 8` \| `read_ahead = 1024 KB` | `sync_ratio = 4` \| `read_ahead = 512 KB` | `sync_ratio = 2` \| `read_ahead = 128 KB` |
| **le9 Workingset** | `clean_min = 5%` \| `clean_low = 10%` | `clean_min = 5%` \| `clean_low = 10%` | `clean_min = 5%` \| `clean_low = 10%` |
| **ZRAM Expansion** | **3.5 GB (3584 MB)** LZ4 Priority 32767 | 3.5 GB | 3.5 GB |
| **LMKD Game Shield** | `oom_score_adj = -900` + `renice -20` | Standard | Standard |

---

## 🚀 Installation

### Method 1: KernelSU Next Manager (Recommended)
1. Download `uclamp_auto_profiler.zip` from the [Releases](https://github.com/juniarafi213/uclamp_auto_profiler/releases) page.
2. Open the **KernelSU Next** app on your device.
3. Navigate to **Modules** -> **Install** -> Select the `.zip` file.
4. Reboot the device.

### Method 2: Manual Installation via Root Shell
```sh
mkdir -p /data/adb/modules/uclamp_auto_profiler
unzip -o uclamp_auto_profiler.zip -d /data/adb/modules/uclamp_auto_profiler/
chmod -R 755 /data/adb/modules/uclamp_auto_profiler/
ln -sf /data/adb/modules/uclamp_auto_profiler/system/bin/uclamp_profiler /data/adb/ksu/bin/uclamp
```

---

## 🛠️ Usage

### Accessing the WebUI
1. Open **KernelSU Next**.
2. Tap on the **Modules** tab.
3. Find **UCLAMP Auto Profiler** and tap the **WebUI** button.
4. Toggle your desired apps into **Game**, **Daily**, or **Battery** profiles.

### Terminal CLI Commands (via Termux or ADB)
```sh
# View current status, active profile, memory, and telemetry
uclamp status

# Manually trigger Game profile
uclamp game

# Manually trigger Daily Balanced profile
uclamp balance

# Manually trigger Battery Saver profile
uclamp battery

# Quick cache purge
uclamp purge

# Assign an app profile directly via CLI
uclamp set_app com.miHoYo.GenshinImpact game
```

---

## 📦 Building from Source

To package the flashable zip locally:
```bash
git clone https://github.com/juniarafi213/uclamp_auto_profiler.git
cd uclamp_auto_profiler
bash build.sh
```
The flashable zip `uclamp_auto_profiler.zip` will be generated in the root directory.

---

## 📜 License
Licensed under the [GNU General Public License v3.0](LICENSE).
