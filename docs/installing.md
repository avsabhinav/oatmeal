# Oatmeal — Installation & Technical Guide

This page is the **technical reference**: how to get the app packaged as a DMG
(or build it from source), the full `mr` CLI reference, configuration, hotkeys,
the optional menu-bar app, and development notes.

> For a short, non-technical "download + install + use" walkthrough, see the
> main [README](../README.md). This page is the deep dive.

---

## 1. Get the app (recommended): the DMG

The easiest install is a drag-and-drop disk image. Download `Oatmeal-<version>.dmg`
and:

1. Double-click the DMG — a volume named **Oatmeal** mounts and a Finder window
   opens showing **`Oatmeal.app`** (the menu-bar app) and an **Applications**
   shortcut.
2. Drag **`Oatmeal.app`** onto the **Applications** shortcut. It lands at
   `/Applications/Oatmeal.app`. **Done** — no terminal, no installer script, no
   venv.
3. Eject the volume.

The app is launched from the menu bar (it has **no Dock icon** — `LSUIElement`),
so look for it in the top-right of your screen after launching.

### First launch / Gatekeeper

The DMG is **Developer ID–signed and notarized by Apple**, and the stapled
notarization ticket travels inside `Oatmeal.app` itself. On a fresh Mac it
opens with a plain double-click — no Gatekeeper warning, and no
right-click → Open step.

If macOS *does* refuse to open it, you are almost certainly running an older
build from before notarization. Confirm what you have, and re-download if
needed:

```sh
spctl -a -vvv -t exec /Applications/Oatmeal.app
# notarized + stapled build: ... accepted
#                              source=Notarization Data
```

### What the DMG installs

`Oatmeal.app` is **self-contained**: it bundles the frozen `mr` CLI and the
`mr-capture` helper inside the app, so a DMG install needs **no** `PATH` setup,
**no** venv, and **no** `launchctl setenv`. The app resolves its own CLI and
sets `MR_CAPTURE_BIN` internally.

---

## 2. Building the DMG from source

If you have a checkout (or want to ship/patch a build), produce a fresh DMG
from the repo root:

```sh
./packaging/make_dmg.sh
```

What it does, in order:

1. **Re-freezes the `mr` CLI from the current source** → `dist-freeze/mr-cli`,
   so the bundled CLI is never stale.
2. **Builds `Oatmeal.app`** via `menu-bar/install.sh`, embedding the frozen CLI
   and `mr-capture` inside the app's `Contents/Resources/`.
3. **Stages a DMG volume** containing only `Oatmeal.app` and an `Applications`
   shortcut (single-drag install).
4. **Writes the image** to `dist/Oatmeal-<version>.dmg` with `hdiutil`
   (compressed UDZO) and opens a Finder drag window.

**Output:** `dist/Oatmeal-0.1.1.dmg` (version comes from `pyproject.toml`).

### Verify the DMG

```sh
hdiutil verify dist/Oatmeal-0.1.1.dmg
```

### Notes & options

- **Heavy + has GUI side effects.** It re-freezes a ~950 MB CLI and calls
  `open` / activates Finder to show the drag window. On a sandboxed/CI shell the
  `hdiutil` mount step may fail — that's expected.
- **Stage-only (no image):** to assemble everything without writing the DMG,
  set `PKG_DMG_STAGE_ONLY=1`:
  ```sh
  PKG_DMG_STAGE_ONLY=1 ./packaging/make_dmg.sh
  ```
  It builds all artifacts and lays out the volume, then exits before `hdiutil`.
- **Adhoc-signed, not notarized** — this is the default `make_dmg.sh` output,
  for local builds. Recipients of such a build hit a Gatekeeper prompt. The
  **published releases are signed and notarized**: build them with `MR_SIGN=1`,
  which requires the Developer ID credentials described in
  [notarization-setup.md](notarization-setup.md).

---

## 3. Build & run from source (no DMG)

The CLI and the menu-bar app are built separately. All commands from the repo
root.

### 3.1 Prerequisites

- macOS 14.2 or later (system-audio tap uses a Core Audio process tap)
- Apple Silicon (transcription runs on Apple's MLX framework)
- Python 3.12+
- Xcode Command Line Tools (`swift`)

### 3.2 Install the `mr` CLI

```sh
pip install -e ".[dev]"
```

### 3.3 Build the `mr-capture` helper

```sh
bash capture/install.sh    # or: cd capture && ./build.sh
```

`capture/install.sh` installs the helper to the repo-local
`capture/.build/release/mr-capture`, which the CLI resolves by default — no
environment needed. To use a system location instead:

```sh
export MR_CAPTURE_BIN=/usr/local/bin/mr-capture
```

### 3.4 Sanity-check + fetch the model (once, needs network)

```sh
mr doctor
mr doctor --fetch-model
```

`mr doctor` prints the macOS version, `out_root`, the helper binary path, the
configured model, and whether it is cached. `--fetch-model` downloads the model
into the standard Hugging Face cache if absent.

> Note: `mr doctor` does **not** check microphone / system-audio permissions —
> see §7.

### 3.5 Batch-install the menu-bar app (optional)

`Oatmeal` is an optional menu-bar app that drives the same `mr` CLI. To build the
`.app`:

```sh
cd menu-bar && ./install.sh      # → menu-bar/.build/Release/Oatmeal.app
```

Drag the resulting `.app` into `/Applications` or launch it in place.

**For a source/dev build only**, make `mr` reachable one of two ways:
- put `mr` on `PATH` (`pip install -e .`), or
- launch the app with `MR_PYTHON=<venv>/bin/python` set (the app resolves `mr`
  from `PATH` first, then `MR_PYTHON`).

The DMG/bundled `Oatmeal.app` is self-contained and needs none of this.

---

## 4. CLI reference

The entry point is `mr` (installed by `pip install -e .`).

| Command | Purpose |
| --- | --- |
| `mr toggle` | **Primary action.** Start recording if idle, else stop (transcribe in background). Ideal for a hotkey. |
| `mr start` | Start recording. |
| `mr stop` | Stop recording; transcribe in the background. |
| `mr status` | Show whether a capture is active (pid, output dir, stamp) and the last transcript. |
| `mr process` | Transcribe an existing `--mic`/`--system` WAV pair (no capture needed). |
| `mr doctor` | Check the environment (macOS version, helper binary, model cache). |
| `mr stop-transcribe` | Stop a running transcription. |
| `mr retranscribe` | Re-run transcription of a past recording. |

### `mr toggle`

```
mr toggle [--json]
```

- `--json` — also write a JSON sidecar when *stopping*.

### `mr start`

```
mr start [--context-json <path>]
```

Spawns `mr-capture` (it keeps running after `mr start` exits) and records the
state. If a capture is already active it prints `already recording (stamp …)`
and exits 0.

- `--context-json` — optional path to a JSON meeting-context file (title /
  attendees / notes). The file is validated as parseable JSON and its raw text
  is persisted as `meeting_context.json` inside the new `recordings/<stamp>/`
  directory, so the background transcriber can attach it to the transcript as
  Obsidian frontmatter later.

### `mr stop`

```
mr stop [--json]
```

Sends SIGINT to the capture helper, waits (up to ~15 s) for the WAVs and
`meta.json` to flush, clears the recording state, and **returns immediately**.
Transcription continues in a detached background process, which writes
`transcripts/<stamp>.md` and posts a macOS notification when done. You can
start a new recording right away even if the previous transcription is still
running. Prints `not recording` if there is no active session.

### `mr status`

Shows `recording: yes/no`, and when active: `pid`, `out_dir`, `stamp`,
`started_at` — plus a `stale pidfile` warning if the helper died. Also prints
the path of the most recent transcript.

### `mr process`

Transcribe an existing WAV pair (handy for re-processing or testing):

```
mr process --mic <wav> --system <wav>
          [--model <hf-repo-id>] [--language <code>]
          [--dedup-threshold <0.0-1.0>] [--json]
          [--stamp <label>] [--out-dir <dir>]
```

- `--mic` — you-side 16 kHz mono WAV (required)
- `--system` — them-side 16 kHz mono WAV (required)
- `--model` — Hugging Face repo id (default: `mlx-community/whisper-large-v3-turbo`)
- `--language` — forced language code (default: `en`)
- `--dedup-threshold` — echo-dedup similarity threshold, 0–1 (default: `0.6`). Echo is removed word by word, so a line that mixes the other speaker's audio with your own keeps your words and loses theirs; a line that was entirely echo disappears. Nothing is ever hidden: a segment that has no word timings to trim is printed with a trailing `*(possible echo)*` marker instead, and the JSON sidecar (`--json`) carries `"echo_suspected": true` on it
- `--json` — also write `<stamp>.json`
- `--stamp` — label for the transcript file (default: the system WAV's stem)
- `--out-dir` — output directory (default: the system WAV's directory)

Writes `<stamp>.md` (and `<stamp>.json` with `--json`) into the output dir.

### `mr doctor`

```
mr doctor [--fetch-model]
```

Prints the macOS version, `out_root`, the helper binary path (or
`helper: MISSING (build capture/ or set MR_CAPTURE_BIN)`), the configured
model, and whether it is cached. With `--fetch-model`, downloads the model
into the standard Hugging Face cache if it is not already present.

### `mr stop-transcribe`

```
mr stop-transcribe [stamp]
```

Stops a running transcription. Prints exactly one line, and exits 0 in each
case: `no transcription running` (nothing in progress), `no transcription
running for <stamp>`, `<stamp> already finished` (the process had ended before
the stop reached it), or `stopped transcription of <stamp>`. Exits 1 only when
the heartbeat carries no PID. A stopped run leaves
`transcripts/<stamp>.STOPPED.md` describing the cancellation — it does **not**
write the `.FAILED.md` "transcription failed" marker.

### `mr retranscribe`

```
mr retranscribe <stamp>
```

Re-runs transcription of a past recording in a detached background worker.
Prints `retranscribing <stamp>` and exits 0 once the worker is started. Exits
1 with a one-line reason if the stamp is unknown, the recording's WAVs
(`mic.wav` / `system.wav`) are gone, a transcription is already running for
that stamp, or the spawn fails. The worker overwrites `transcripts/<stamp>.md`
when it finishes (it never deletes an existing transcript early) and removes
any `.FAILED.md` marker on success.

### Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success (including `mr stop` with nothing to stop, and `mr start` when already recording). |
| `1` | `mr doctor --fetch-model` failed to download the model (network/HF error); `mr stop-transcribe` heartbeat with no PID; `mr retranscribe` failure (unknown stamp, WAVs gone, already running, or spawn failed). |
| `2` | Usage / parameter error (e.g. `--mic` file not found, bad `--dedup-threshold`). |
| `3` | Model not cached (offline cache-only transcription). Fix: `mr doctor --fetch-model`, then re-run `mr stop` (state is intentionally kept so you can retry). |

---

## 5. Configuration

Config file: `~/.config/mr/config.toml` (optional — defaults are used when the
file or individual keys are absent). See [config.toml.example](../config.toml.example):

```sh
mkdir -p ~/.config/mr && cp config.toml.example ~/.config/mr/config.toml
```

| Key | Default | Meaning |
| --- | --- | --- |
| `out_root` | `~/Meetings` | Root directory holding `recordings/` and `transcripts/`. |
| `model` | `mlx-community/whisper-large-v3-turbo` | mlx-whisper model (HF repo id or local path). |
| `language` | `en` | Forced transcription language (ISO code). |
| `dedup_threshold` | `0.6` | Echo-dedup similarity threshold (0–1) when merging the two streams. |
| `keep_audio` | `true` | Keep the raw WAV files after transcription (re-processable). |

Recording state lives in `<out_root>/.state/recording.json` (pid, out_dir,
stamp, start time).

---

## 6. Hotkey: bind `mr toggle`

The intended workflow is: press a hotkey before a call, press it again after.

### macOS Shortcuts (recommended)

1. Open **Shortcuts** → New Shortcut.
2. Add a **Run Shell Script** action with the script `mr toggle`.
3. Bind the shortcut to a global hotkey (e.g. **⌥⌘R**):
   **System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ Shortcuts** → set your
   shortcut. (Or use the shortcut's own "Keyboard Shortcut" setting in the
   Shortcuts editor.)

> Tip: make sure `mr` is on the `PATH` that Shortcuts uses; if you installed
> with a venv, use the full path (e.g. `~/.venvs/mr/bin/mr toggle`).

### Raycast (Script Command)

Add a Script Command with:

- Command: `mr toggle`
- Input: none (stdout = output)
- Then assign a hotkey (e.g. **⌥⌘R**) to the command.

---

## 7. Permissions

`mr-capture` needs **two** permissions, both granted the first time a capture
starts (TCC prompt; the binary embeds usage descriptions and is adhoc-signed):

- **Microphone** — records your mic stream (You).
- **System Audio Recording** (macOS 14.2+) — records the speaker audio (Them).

Grant them under **System Settings ▸ Privacy & Security** — enable the entry
for the capturing process under **Microphone**, and the corresponding system
audio / Screen Recording entry for the system-audio capture. The entry may
show the `mr-capture` helper or the app that launched it (Terminal /
Shortcuts). **If a permission is denied, the recording may still appear to
work but the track can be silent** — see
[docs/permissions-troubleshooting.md](permissions-troubleshooting.md) for how
to verify your capture actually has audio.

For the menu-bar app specifically, the TCC prompts are attributed to the app
(`Oatmeal` / the `mr-capture` helper it launches), **not** a Terminal. If a
prompt was previously granted to Terminal, it may not carry over to the app;
re-grant for the app-path per the permissions guide.

---

## 8. Output layout

```
~/Meetings/                          # out_root
├── .state/recording.json            # active-session state (pid, out_dir, stamp)
├── recordings/<stamp>/              # <stamp> = YYYY-MM-DD_HHMM
│   ├── mic.wav                      # You track (16 kHz mono)
│   ├── system.wav                   # Them track (16 kHz mono)
│   ├── meta.json                    # capture metadata (device, samples_written, …)
│   └── meeting_context.json         # optional: attached meeting context (see below)
└── transcripts/
    ├── <stamp>.md                   # attributed transcript (You / Them)
    └── <stamp>.json                 # optional, with --json
```

---

## 9. Meeting context (calendar)

If a meeting context is attached at start time (via `mr start --context-json <path>`),
the transcript picks it up automatically:

- **`meeting_context.json`** is stored in `recordings/<stamp>/` next to the WAVs.
  The detached background transcriber reads it when the call ends.
- The `.md` transcript is then written with an **Obsidian YAML frontmatter** block
  at the top — `title` (event title, falling back to the stamp), `date` (event
  start, falling back to the recording date), `attendees` (a YAML flow list,
  omitted when empty), `notes` (omitted when empty), `duration` (e.g. `42m 10s`),
  and `source` (the `recordings/<stamp>/` dir). These become queryable Obsidian
  properties, so you can find, sort, and link meetings from your vault. When no
  context is attached, the `.md` is exactly the same as before (no frontmatter),
  and the JSON sidecar (with `--json`) gains a `"context"` key with the raw
  context dict.

Example frontmatter:

```
---
title: Weekly 1:1
date: 2026-10-15T10:00:00Z
attendees: [Alice, Bob]
notes: Discuss Q3 roadmap
duration: 42m 10s
source: recordings/2026-08-24_1432/
---
```

**Menu-bar:** the `Oatmeal` app has a **"Start Recording from Calendar…"**
submenu (tag 708) that lists Apple Calendar events from the last 1 hour through
the next 2 hours. Picking an event starts a recording with that meeting
attached as context (the app builds the JSON with `mr start --context-json`);
the **plain Start Recording** item keeps working without any calendar, and the
feature degrades gracefully if Calendar permission is not granted. EventKit
access is owned entirely by the menu-bar app (never the Python core).

---

## 10. Menu-bar app (beta)

`Oatmeal` is an optional menu-bar app (no Dock icon — `LSUIElement`) that drives
the same `mr` CLI: **Start Recording**, **Stop Recording & Transcribe**, **Check
Active Transcriptions…**, **Change Storage Location…**, **Open Folder ▸ Recordings /
Transcripts**, and **Quit**. Stop returns immediately; transcription continues in
the background and is surfaced via **Check Active Transcriptions…** and a
completion notification. It is a pure shell around `mr` — it never spawns
`mr-capture` or writes config/state itself, and it only refreshes when you open the
menu (no polling).

- **Build + install:** `cd menu-bar && ./install.sh` →
  `menu-bar/.build/Release/Oatmeal.app` (drag into `/Applications` or launch in place).
- **Manual test + permissions:** see
  [docs/menu-bar-manual-test.md](menu-bar-manual-test.md) — the app is the
  responsible process for the Microphone / System Audio TCC prompts.
- **New menu actions need a re-frozen CLI.** The app prefers the frozen CLI
  embedded in `Oatmeal.app/Contents/Resources/mr-cli/` (see
  `AppInfo.mrCandidates()`), so the **Stop Transcription** button and
  **Re-transcribe…** menu row only exist inside a packaged app after you re-run
  `packaging/freeze_cli.sh` (or `packaging/make_dmg.sh`, which re-freezes from
  source). A source checkout that runs the app with `MR_PYTHON` set uses the
  live Python and needs no re-freeze.

---

## 11. Project layout & developing

```
mr/            # Python package: cli, config, state, core/ (capture, transcribe, merge, output)
capture/       # SwiftPM package → mr-capture helper (build.sh, install.sh, Info.plist)
menu-bar/      # Oatmeal Swift menu-bar app (build.sh, install.sh, Package.swift)
packaging/     # freeze_cli.sh (PyInstaller), make_dmg.sh (DMG)
tests/         # core unit tests (transcriber mocked); menu-bar/Tests has Swift XCTest
examples/      # sample aligned WAVs + generated transcript
docs/          # architecture, permissions & troubleshooting, manual test, this guide
assets/        # branding (app icon, menu-bar glyph)
config.toml.example
pyproject.toml # `mr` entry point, deps (mlx-whisper, typer, soundfile, rapidfuzz)
```

### Develop / test

```sh
pip install -e ".[dev]"
ruff check mr tests
pytest
```

Rebuild the capture helper after Swift changes: `cd capture && ./build.sh`.
Rebuild the menu-bar app: `cd menu-bar && ./build.sh`.

### Continuous integration

A GitHub Actions workflow (`.github/workflows/ci.yml`) runs on every push to
`main` and on every pull request. It executes on an Apple Silicon macOS 15
runner and:

1. Installs the Python package (`pip install -e ".[dev]"`)
2. Lints and tests the Python core — `ruff check mr tests` and `pytest`
3. Builds both Swift helpers — `capture/build.sh` (`mr-capture`) and
   `menu-bar/build.sh` (`Oatmeal`), then runs the menu-bar XCTest suite with
   `swift test`