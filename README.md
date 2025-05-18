# sFlow Traffic Monitor & Trigger

A Lightweight CLI utility that shows live traffic for a chosen interface and runs custom scripts when usage crosses the limits you set.

**By:** Ali E. Mubarak (Craniax) - https://www.linkedin.com/in/craniax/

---

## 1-Minute Install

```bash
# grab the code
git clone https://github.com/rootCraniax/sflow-net-monitor.git
cd sflow-net-monitor

# make installer executable and run it
chmod +x install.sh
sudo bash install.sh
```

The installer will:
1. Detect your OS and bring in `hsflowd`, `node`, etc.
2. Ask which interface to watch.
3. Drop everything under `/opt/net-monitor`.
4. Register a systemd service so monitoring starts on boot.

### After install

```bash
net_monitor        # start the live dashboard (Ctrl-C to quit)
```

A log of every trigger lives in `/opt/net-monitor/trigger.log`.

---

## Tweaking thresholds & triggers
Edit `/opt/net-monitor/config.json` – main keys:

```jsonc
{
  "pps_threshold": 100000,        // alert if packets per second ≥ this
  "mbps_threshold": 100,          // alert if Mbps ≥ this
  "ok_delay_secs": 60,           // wait before running OK script
  "trigger_script": {
    "OK": "./scripts/reset.sh",
    // "WARNING": "./scripts/warning.sh",
    // "ABNORMAL": "./scripts/abnormal.sh",
    "CRITICAL": "./scripts/critical.sh"
  }
}
```
Each script in `/opt/net-monitor/scripts/` receives env-vars `PPS`, `MBPS`, `THRESHOLD_PPS`, `THRESHOLD_MBPS`.

---

## hsflowd basics
We install & configure `hsflowd` to export samples to `127.0.0.1:6343` with:
* `sampling=1` (adjust in `config.json` if you change traffic load)
* `polling=2` seconds for counter stats

Config file: `/etc/hsflowd.conf`
Restart if you change it:
```bash
sudo systemctl restart hsflowd
```

---

## Tested Platforms
* Ubuntu 18.04, 20.04, 22.04, 24.04
* Debian 10, 11, 12
* AlmaLinux 9.5

---

MIT License – do what you want, just keep the credits. :)
