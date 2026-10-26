# Changelog

All notable changes made during the re-engineering pass of this repository.
This document records, per item: what was faulty, what was changed/upgraded,
and how it was verified.

---

## 1. Licensing / Copyright removal

**Faulty / requirement**
- The repository shipped with a `LICENSE` file and GPLv3 copyright headers in
  config files. These were to be removed for the re-write.

**Change**
- Deleted `LICENSE`.
- Removed the copyright/SPDX header block from
  `img-config/printer-data/mainsail.cfg`.

**Verification**
- Grep for `license`, `copyright`, `GPL`, `SPDX` returned no remaining matches.

---

## 2. #442 — `img-config/power_monitor.sh` robustness

**Faulty**
- Relied on external helpers (`have_cmd`, `gpioinfo`) and integer-only sleeps
  that could not express sub-second debounce intervals portably.
- Supercap enable logic only handled one tool syntax; could silently fail.
- `start_monitors` did not confirm both monitors stayed alive, so power-loss
  protection could be lost without notice.
- `handle_power_cut` could leave the system in a half-shutdown state
  (`exec "$0"` re-entry, unguarded `poweroff`).

**Upgraded**
- Added pure-bash `ms_sleep` (no external interpreter dependency).
- Removed `gpioinfo`/`have_cmd`/`SUPERCAP_TIMEOUT` dependencies.
- Hardened `enable_supercap` (libgpiod v1 and v2, with `pgrep` fallback).
- `start_monitors` now waits for both monitors to remain alive and honours
  `REQUIRE_MONITOR`.
- `wait_any_event` now uses `wait -n`.
- Replaced `exec "$0"` re-entry with a supervision `while true` loop.
- `handle_power_cut` fixed: `systemctl poweroff || true; return 0`.
- Made the libgpiod version log optional (v2 tool set has no `gpioinfo`).
- `power_monitor.service` (defined in `Neo9labs.sh`) now uses
  `Restart=on-failure`, `RestartSec=5`, `After=klipper.service`, and
  user-relative `ExecStart` with path-repair logic.

**Verification**
- Structural review (balanced braces/quotes). Full shell lint was not possible
  on the build host (see "Limitations").

---

## 3. #441 — Fan thermal safety

**Faulty**
- `idle_timeout: 43200` in `printer-confs/{n4,n4pro,n4plus,n4max}/section_fans.cfg`
  meant the controller fan dropped to 50% for 12 hours and then turned **off**,
  risking mainboard/stepper-driver overheating.

**Upgraded**
- Set `idle_timeout: 0` on all four models so the controller fan never drops to
  the idle/off state.

**Verification**
- Generated config for each model shows `idle_timeout: 0`.

---

## 4. #444 / #445 / #420 / #409 / #398 — Host ↔ MCU timing stability

**Faulty**
- Klipper host process, its threads, and the UART IRQ could migrate across CPU
  cores. Under load this delayed TX-DMA completion and caused missed
  digital-out events, "timer too close", and MCU shutdowns.

**Upgraded (new files)**
- `img-config/affinity-setup.sh` installs:
  - `/usr/local/bin/neo9labs-affinity.sh` — idempotent pinning helper.
  - `affinity.service` — applies pinning at boot and 20s post-start.
  - `/etc/udev/rules.d/90-neo9labs-serial-affinity.rules` — re-applies IRQ
    affinity when the MCU serial device (re)appears.
  - `/etc/sysctl.d/10-disable-rt-group-limit.conf` — disables the RT bandwidth
    cap so RT klippy threads are never throttled.
  - Pins klippy + all threads to the reserved core, pins the serial IRQ,
    moves Ethernet/MMC IRQs off the reserved core, and sets
    `IRQBALANCE_BANNED_CPUS`.
- `img-config/uart-dma-fix.sh` — TX-DMA mitigation plus a persistent
  `neo9labs-uart.conf` modprobe drop-in. Live UART driver reload is guarded
  so an in-use / console-attached driver is never unloaded.

**Verification**
- Braces/quotes balanced. The resolved core numbers are propagated into the
  installed helper (so systemd/udev invocations use the correct cores) and the
  irqbalance banned-CPU mask was corrected to `1 << core`.

---

## 5. #440 / #410 / #412 — Homing, step edges, leveling coordinates

**Faulty**
- Homing speeds were hardcoded, ignoring per-model overrides.
- `endstop_pin:probe:` (missing space) and `z_offset = 0.0` (wrong delimiter)
  produced malformed / non-applied config.
- Probe X/Y offsets and bed-mesh minimums were missing, so first-layer probing
  could run off the sheet.
- `STEPPER_STEP_BOTH_EDGE` warnings came from a host/firmware version mismatch
  (deprecated MCU code), not a config value.

**Upgraded**
- `base.cfg` stepper_x/y now template `{{ x_homing_speed }}` /
  `{{ x_second_homing_speed }}` (and Y equivalents).
- Added homing speeds per model: n4/n4pro `50/25`, n4plus/n4max `40/20`.
- Fixed `endstop_pin: probe:` and `z_offset: 0.0`.
- Added `probe_x_offset` / `probe_y_offset` and `bed_mesh_min` placeholders in
  `base.cfg` with per-model values (n4/n4pro `30,21`; n4plus/n4max `30,25`).
- `rpi-mcu-install.sh` now prints a host-vs-MCU version consistency warning
  (`warn_mcu_version_mismatch`) in the STM32 flash path, documenting that the
  MCU must be reflashed in the same session to clear the warning.

**Verification**
- `generate_conf.py` run for all four models produced **0** leftover
  `{{ ... }}` placeholders and the expected resolved values.

---

## 6. #418 — Filament runout temperature restore

**Faulty**
- `runout_gcode` / `PAUSE` could overwrite the resume temperature with `0`,
  causing a cold resume after a runout.

**Upgraded**
- `runout_gcode` stores `RESUME.etemp` and `UNLOAD_FILAMENT.prev_temp` from the
  extruder target.
- `PAUSE` guards `{% if RESUME.etemp|int <= 0 %}` before overwriting.

**Verification**
- Manual review of the macro flow.

---

## 7. #428 — Z-offset persistence (`generate_conf.py`)

**Faulty**
- `_values_match` was case/format sensitive.
- `_comment_line` lost indentation.
- `_find_SAVE_CONFIG_data` only understood one delimiter.
- Comments starting with `;` could be mis-parsed.

**Upgraded**
- `_values_match` is now numeric-tolerant and polarity-insensitive.
- `_comment_line` preserves indentation.
- `_find_SAVE_CONFIG_data` handles both `:` and `=` delimiters.
- Comments and `;` lines are skipped.

**Verification**
- `python -c ast.parse` OK; generator output verified for all models.

---

## 8. #431 — Orca profile bundles

**Faulty**
- Bundles contained macOS junk (`__MACOSX`, `.DS_Store`).
- Hardcoded `print_host: 10.10.3.6` and `printhost_apikey`.
- Bundle-local `inherits` IDs did not resolve after import.

**Upgraded**
- New `orca-profiles/repair_orca_bundles.py`:
  - remaps `inherits` IDs,
  - strips `print_host` / `print_host_webui` / `printhost_apikey`,
  - removes macOS junk,
  - bumps bundle version to `2.0.0`.
- Applied to all four bundles.

**Verification**
- Each bundle: 6 entries, 0 macOS-junk entries, no `print_host` /
  `printhost_apikey`, and 0 unresolved `-Neo9labs` local inherits.

---

## 9. #421 — Pre-print delay

**Faulty**
- `PRINT_START` heated the bed first and only then the extruder, lengthening
  total heat-up time.

**Upgraded**
- `PRINT_START` now starts extruder heating in parallel with the bed (before
  `BED_TEMPERATURE_WAIT`).

**Verification**
- Manual review of the macro flow.

---

## 10. #405 / #417 / #437 — Hardware / board detection

**Faulty**
- No distinction for Type-C toolheads; unsupported boards (pre-V2.3) were not
  gated, allowing misconfiguration.

**Upgraded**
- `set-printer-model.sh` adds a Type-C toolhead prompt and
  `warn_if_unsupported_board()` (V2.3 gate). The model flag line gets a
  `-typec` suffix.
- `Neo9labs.sh extract_model_and_motor` parses the typec suffix plus an
  optional motor current.

**Verification**
- Manual review of argument parsing.

---

## 11. #416 — Host IP display

**Upgraded (new file)**
- `img-config/ip-publish.sh` writes `~/printer_data/config/network.cfg` with
  `_NET_INFO` / `SHOW_IP` macros.
- `[include network.cfg]` added to `base.cfg`; `run_fixes` creates a placeholder
  and runs the publisher.

**Verification**
- Generated config includes `[include network.cfg]`.

---

## 12. #443 / #424 / #436 — Integrations hardening

**Faulty**
- Hardcoded `/home/mks/` paths in `moonraker.conf`.
- `channel: dev` instead of `stable`.
- No tooling to rebuild Asvc, detect service conflicts, or prune redundant
  update managers.

**Upgraded (new file)**
- `img-config/integrations.sh` with subcommands mapped to
  `asvc` / `conflicts` / `prune` / `all` (`rebuild_asvc`, `check_conflicts`,
  `prune_update_managers`).
- `moonraker.conf`: `/home/mks/` → `~/`, `channel: dev` → `stable`.
- Wired into `run_fixes`.

**Verification**
- Manual review; `moonraker.asvc` is now managed by `integrations.sh`.

---

## 13. #426 — Reflash-required update notice

**Upgraded**
- `Neo9labs.sh process_repo_update` warns when a `REQUIRES_REFLASH*`
  sentinel is present after a pull.

**Verification**
- Manual review.

---

## 14. General bug sweep (additional fixes)

| File | Faulty | Upgraded |
| --- | --- | --- |
| `img-config/update-ssh-keys.sh` | Rollback copied old keys without privileges and could fail; `$?` checks after `sshd -t`. | `shopt -s nullglob` + array backup, `sudo cp -a` rollback, `if ! sudo sshd -t` checks. |
| `img-config/usb-storage-automount.sh` | Hardcoded `USER_NAME=mks` and `/home/mks/...` mount path. | Resolves the invoking user dynamically; mount path derives from the real home. |
| `img-config/affinity-setup.sh` | irqbalance banned-CPU mask was wrong (`(1<<3)-1`); installed helper lost clamped core numbers. | Mask is now `1 << core`; clamped cores propagated via `sed` into the installed helper. |
| `img-config/uart-dma-fix.sh` | Unconditional UART driver unload could drop a live serial console. | Reload guarded by driver-identity and `/proc/cmdline` console check. |
| `img-config/rpi-mcu-install.sh` | No host/firmware version guidance (#410). | Added `warn_mcu_version_mismatch()` and call in the STM32 path. |
| `Neo9labs.sh` | Menu/CLI had no entry points for the new tools. | Added menu items 11/12/13 and wrappers `affinity_setup`, `uart_dma_fix`, `integrations_repair`, plus CLI dispatch and help entries. |

**Verification**
- Brace/quote balance scan across all edited shell scripts (balanced/even).
- Grep confirmed no remaining hardcoded `/home/mks` outside intentional
  detection comments.

---

## 15. Terminal UI redesign + interactive-script hardening

**Faulty / rough edges**
- The main and advanced menus were hand-formatted blocks of `printf`, with
  hardcoded 58-character rules, duplicated prompts, and no terminal-width or
  colour-capability handling.
- State (branch/model/kernel) was printed ad hoc and could be empty/stale.
- `clear_screen` depended on `tput`, which fails on dumb/serial terminals.
- Menus did not handle EOF/Ctrl-D cleanly.
- `-y/--yes` still prompted during printer.cfg diff and config selection.
- `apply_configuration` could continue after a failed backup and copied the new
  config non-atomically.
- `moonraker_update_manager` wrote blocks even when `moonraker.conf` was absent,
  and could emit an empty `primary_branch`.
- `process_repo_update` called `git` before verifying the repo directory.

**Upgraded**
- Added a small UI layer: `ui_header`, `ui_rule`, `ui_section`, `ui_item`,
  `ui_center`, `ui_confirm`, `ui_read`, `ui_pause`, and
  `ui_info`/`ui_ok`/`ui_warn`/`ui_err`.
- Redesigned the Control Center and Advanced Options screens with grouped
  sections, aligned labels/descriptions, and a live branch/model/kernel bar.
- Terminal adapts to 60-100 columns, honours `NO_COLOR`/`TERM=dumb`, and clears
  with ANSI sequences instead of `tput`.
- Menu reads handle EOF and strip stray whitespace; invalid choices give
  actionable messages.
- `-y/--yes` now installs all configuration files and skips diff prompts.
- Printer config writes use a staged temp file + atomic `mv`; backup failure now
  aborts before touching `printer.cfg`.
- Added command checks (`git`, `python3`, `nmtui`) and model validation before
  invoking the generator.
- Model parsing no longer shells out to `cut`/`sed`/`tr` per field.
- `moonraker_update_manager` validates the config file and falls back to `main`
  when a repo has no resolvable branch.
- Repo updates verify the checkout before invoking `git`, resolve revisions with
  error checks, and use a single `ui_confirm` flow.
- `moonraker.conf`: fixed `primary_branch:main` -> `primary_branch: main`.

**Verification**
- `bash -n Neo9labs.sh` (Git for Windows bash 5.2) -> syntax OK.
- Rendered main and advanced menus with sample branch/model/kernel values;
  verified alignment, truncation, and colourless fallback.
- `generate_conf.py` run for all four models -> exit 0, no unresolved
  `{{ ... }}` placeholders.
- `configparser` loads `moonraker.conf` (13 sections); mobileraker branch parses
  as `main`.
- `Neo9labs.sh --help` renders the updated command reference.

---

## 16. Custom Fluidd / Mainsail favicon

**Faulty / requirement**
- A custom `favicon.ico` was provided but not shipped or applied to either web
  interface.

**Upgraded**
- Added `img-config/webui/favicon.ico` (16/32/48 px, RGBA).
- New `install_webui_favicon` helper copies it into `~/fluidd/favicon.ico` and
  `~/mainsail/favicon.ico` when those interfaces are installed.
- Existing favicons are backed up once as `favicon.ico.neo9labs.bak` before
  replacement; identical files are left untouched, so the operation is
  idempotent.
- Applied from `run_fixes` (every script launch) and when installing
  configuration files.
- Guarded the existing Fluidd custom-logo symlink so it is only created when
  `~/fluidd` exists.

**Verification**
- Simulated a `HOME` with both web roots and an old Fluidd favicon: both files
  were replaced, the backup was created, and a second run changed nothing.
- `bash -n Neo9labs.sh` -> syntax OK.

---

## 17. Neo9labs rebrand

**Upgraded**
- Renamed the main script to `Neo9labs.sh`, the project directory references to
  `~/Neo9labs`, and the flag file to `/boot/.Neo9labs.txt`.
- Renamed image assets to `pictures/Neo9labs.png` and
  `pictures/logo_neo9labs.svg`.
- Replaced user-facing vendor model wording with `Neo9labs` in the menu, docs,
  model picker and printer config comments.
- Updated update-manager section names, repository paths and URLs to
  `neo9labs/Neo9labes`, `neo9labs/display_connector` and
  `neo9labs/display_firmware`.
- Regenerated the OrcaSlicer bundle names and display names with the new brand.
- Updated the git `origin` remote to `neo9labs/Neo9labes`.

**Compatibility**
- Kept `n4*` model keys, Klipper config identifiers and the Orca
  `inherits` / `compatible_printers` IDs unchanged because those reference
  profiles and hardware definitions that Orca supplies.
- `img-config/printer-data/data.mdb` is a binary Moonraker LMDB cache rather
  than text, so it was not string-patched.

**Verification**
- `bash -n Neo9labs.sh` -> syntax OK.
- All four Orca bundles pass ZIP/JSON integrity checks and preserve their
  upstream parent IDs.
- `generate_conf.py` still renders all four model configurations.

---

## Limitations

- The first re-engineering pass had no real shell available on the build host,
  so those shell edits were limited to structural scans and manual review. The
  UI pass was syntax-checked with Git for Windows `bash -n`; `shellcheck` was
  still not available, and no live printer was used for runtime testing.
- Python files were validated with `python -c ast.parse`.
- Affinity / RT-kernel code from v0.1.7 is referenced by service name
  (`affinity`, `display`) but implemented by the setup scripts here; it was not
  present as compiled artifacts in the repository.

---

## Files added

- `img-config/affinity-setup.sh`
- `img-config/uart-dma-fix.sh`
- `img-config/integrations.sh`
- `img-config/ip-publish.sh`
- `img-config/webui/favicon.ico`
- `orca-profiles/repair_orca_bundles.py`

## Files renamed

- Main shell entry point -> `Neo9labs.sh`
- Project image -> `pictures/Neo9labs.png`
- Project logo -> `pictures/logo_neo9labs.svg`
- OrcaSlicer bundles -> `Elegoo Neo9labs*.orca_printer`

## Files deleted

- `LICENSE`
