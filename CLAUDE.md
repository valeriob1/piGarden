# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

piGarden is a Bash script suite that manages an irrigation system built on a Raspberry Pi: it drives solenoid valves (electrovalvole) via GPIO or pluggable drivers, reads rain/soil sensors, checks online weather, schedules watering via cron, and exposes a TCP socket API and MQTT status feed for a companion web UI (piGardenWeb). There is no build step, package manager, or test suite — it's run directly as a shell script, normally on a Raspberry Pi.

## Running it

```bash
./piGarden.sh <command> [args...]
```

Run with no arguments (or an unknown command) to print full usage (`show_usage` in [piGarden.sh](piGarden.sh)). Key commands: `init`, `open <alias> [force]`, `open_in <start_min> <stop_min> <alias> [force]`, `close <alias>`, `close_all [force]`, `ev_status_all`, `json_status`, `mqtt_status`, `check_rain_online`, `check_rain_sensor`, `start_socket_server [force]` / `stop_socket_server`, and the `set_cron_*` / `add_cron_open` / `add_cron_close` family for crontab management.

It requires `/etc/piGarden.conf` to exist (copy from [conf/piGarden.conf.example](conf/piGarden.conf.example)) — the script exits immediately if that file is missing. Off a Raspberry Pi, external tool paths (`GPIO`, `JQ`, `CURL`, `CRONTAB`, `MOSQUITTO_PUB`, etc.) in that conf file won't resolve, so most commands can't actually execute; read/reason about the code instead of expecting it to run locally.

There is no linter/test runner configured in this repo. If validating shell syntax, `bash -n piGarden.sh` or `shellcheck` are reasonable ad hoc choices, but neither is wired into any project command.

Ad hoc manual debug hooks exist at [debug/debug1.sh](debug/debug1.sh) and [debug/debug2.sh](debug/debug2.sh), invoked via `./piGarden.sh debug1`/`debug2` — they're empty scratch files meant to be filled in temporarily while testing on real hardware.

## Architecture

### Entry point and includes

[piGarden.sh](piGarden.sh) is the entry point: it loads `/etc/piGarden.conf`, sources every file in `include/`, calls `setup_drv` (see below), then dispatches `$1` through a big `case` statement to the matching function. Each include file owns one concern:

- [include/drv.include.sh](include/drv.include.sh) — driver dispatch layer (see below)
- [include/cron.include.sh](include/cron.include.sh) — reads/writes the user's crontab for scheduled open/close, delimiting each entry with `# START cron <type> <arg>` / `# END cron <type> <arg>` marker comments so entries can be found and removed later
- [include/rain.include.sh](include/rain.include.sh) — rain detection (sensor + online weather) and the logic to close all valves when it's raining
- [include/sensor.include.sh](include/sensor.include.sh) — generic sensor state storage/lookup (moisture, temperature, fertility, illuminance) and the soil-moisture auto-close/no-open checks
- [include/events.include.sh](include/events.include.sh) — the event/hook dispatch system (see below)
- [include/socket.include.sh](include/socket.include.sh) — TCP socket server (via `tcpserver`) that lets remote clients invoke commands over the network, with optional user/password auth

### Driver plugin system

Solenoids, the power supply, the rain sensor, and the weather service are all addressed indirectly through a `drv:<name>` indirection instead of a raw GPIO number. For example `EV1_GPIO=drv:sonoff_tasmota_http` or `WEATHER_SERVICE="drv:openweathermap"`. `WEATHER_SERVICE` is the one exception that may also be written without the prefix: [piGarden.sh](piGarden.sh) adds `drv:` itself (`WEATHER_SERVICE="openweathermap"` becomes `drv:openweathermap`; empty means `drv:wunderground`; `none` disables it). The production Pi uses the unprefixed form. On startup, `setup_drv` (in [include/drv.include.sh](include/drv.include.sh)) scans the config for every `drv:*` reference, sources the matching files under `drv/<name>/*.include.sh`, and calls that driver's `drv_<name>_setup` if present.

At call sites, functions like `drv_rele_open`, `drv_rele_close`, `drv_rain_sensor_get`, `drv_rain_online_get`, `drv_supply_positive`/`drv_supply_negative` check via `get_driver_callback` whether the target is a `drv:*` reference: if not, they fall back to talking to the Raspberry Pi GPIO directly through the `$GPIO` binary; if so, they call the driver's `drv_<name>_<callback>` function instead.

Each driver under `drv/<name>/` is a set of optionally-present include files, sourced in this fixed callback order: `config`, `common`, `init`, `rele`, `supply`, `rainsensor`, `rainonline`, `setup` (i.e. `drv/<name>/rele.include.sh` defines `drv_<name>_rele_init/open/close`, etc.). [drv/sample/](drv/sample/) is a documented skeleton showing every callback a driver can implement; use it as the template for new drivers. Existing drivers: `openmeteo`, `openweathermap`, `wunderground` (weather-only), `rainsensorqty` (quantity-based rain sensor), `remote`, `sonoff_tasmota_http`, `spb16ch` (relay-only drivers for remote/networked valve hardware).

### Event/hook system

[include/events.include.sh](include/events.include.sh)'s `trigger_event <event_name> <args...>` is called at fixed points throughout the codebase (e.g. `ev_open_before`/`ev_open_after`, `ev_close_before`/`ev_close_after`, `check_rain_sensor_change`, `init_before`/`init_after`, `cron_add_before`/`cron_add_after`, `exec_reboot_before`/`exec_reboot_after` — see the `case` in `trigger_event` for the full list and each event's exact positional arguments). For each event it runs every executable file in `events/<event_name>/`, passing that event's specific args plus a trailing epoch timestamp. If a hook script exits non-zero, the event chain stops and (for the `_before` events on `ev_open`/`ev_open_in`) the underlying action is aborted — this is the mechanism used to veto opening a valve from a hook script. [events/scripts/](events/scripts/) holds example hook implementations (email notification, HTTP notify, test hooks); the directories directly under `events/` (e.g. `events/ev_open_before/`) are where you'd symlink/drop scripts to activate a hook for a given event.

### State and configuration

- Runtime state (current valve open/closed states, last rain timestamps, last weather JSON, per-sensor readings) lives as flat files under `$STATUS_DIR` (configured in `piGarden.conf`, see [state/](state/)) — no database.
- All tunables (GPIO pin numbers, valve aliases `EV<n>_ALIAS`/`EV<n>_GPIO`, sensor definitions `SENSOR<n>_ALIAS`, monostable vs. bistable valve behavior, weather service selection, rain-lockout durations, MQTT/socket-server credentials, external binary paths) come from `/etc/piGarden.conf`, sourced verbatim as shell at startup. [conf/piGarden.conf.example](conf/piGarden.conf.example) is the canonical annotated reference for every setting; the other `conf/piGarden.conf.*.example` files show variants for specific driver setups (remote, spb16ch, sonoff_tasmota_http, rainsensorqty).
- Valves and sensors are addressed by 1-indexed number internally but by user-facing `ALIAS` string everywhere in the CLI/API; `ev_alias2number`/`sensor_alias2number` (both use indirect variable expansion, e.g. `EV"$i"_ALIAS`) do the lookup by scanning `1..EV_TOTAL`/`1..SENSOR_TOTAL`.
- Bistable valves are pulsed (brief supply-voltage-reversal + relay pulse) rather than held energized; monostable valves (`EV_MONOSTABLE=1` globally, or `EV<n>_MONOSTABLE=1` per valve) and remote-driver valves are simply held open/closed instead — this branching is visible directly in `ev_open`/`ev_close` in [piGarden.sh](piGarden.sh).
- A directory-based lock (`mkdir`/`rmdir` on `$LOCK_FILE`, in `lock`/`unlock` in [piGarden.sh](piGarden.sh)) serializes valve open/close operations, with a retry-and-give-up-after-10s policy.

### Comments and identifiers

Most inline comments and many function/variable descriptions in this codebase are in Italian; code and CLI-facing strings are in English. Match whichever convention is already present in the section you're editing.
