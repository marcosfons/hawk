# Changelog

All notable changes to hawk. Versions follow [Semantic Versioning](https://semver.org);
the app's About box and `CFBundleShortVersionString` show the current one.

## [Unreleased]

### Added
- Overview: CPU per core, GPU, temperatures, memory and swap, disk and network
  I/O, power and charging, fan gauges with Auto, Curve and Fixed control.
- CPU and Memory tabs: every process with power, CPU time, wake-ups, disk,
  memory growth and peak; search, sort, quit.
- Energy tab: energy per app over 10 minutes, an hour or since unplugging, and
  the battery time quitting an app would give back. Charging status.
- Network tab: traffic per process.
- Storage tab: reads a storage registry scan; safe deletions with guards,
  simulators, DerivedData, Docker volumes, WhatsApp media per chat (read-only).
- Alerts, in the app and as notifications.
- Root helper `hawkd` for fan control and system process figures.
- `hawk` command-line monitor.
- Logging with timings of every step and a main-thread stall watchdog.
