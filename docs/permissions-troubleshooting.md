# Permissions & Troubleshooting

Covers the permissions Oatmeal needs (Microphone, System Audio, and Calendar
for the menu-bar calendar path), what `mr doctor` does (and does not) check,
and answers to common problems.

## Required permissions

`mr-capture` records two streams, each gated by a separate macOS (TCC)
permission:

| Permission | What it records | Where it is granted |
| --- | --- | --- |
| **Microphone** | Your mic track (`mic.wav` → *You*) | System Settings ▸ Privacy & Security ▸ **Microphone** |
| **System audio capture** (macOS 14.2+, Core Audio process tap) | Your speakers' output (`system.wav` → *Them*) | System Settings ▸ Privacy & Security — the system-audio / Screen Recording entry for the capturing process |

### How the prompts appear

- Both TCC prompts surface **the first time a capture starts** (first
  `mr start` / `mr toggle` / `mr process`, or the first capture started from
  the menu-bar app).
- **The Microphone prompt is attributed to Oatmeal.** The microphone
  entitlement (`com.apple.security.device.audio-input`) is held by the
  **Oatmeal** app (`packaging/entitlements/app.entitlements`). The
  `mr-capture` helper deliberately holds **no** microphone entitlement and has
  no microphone usage description of its own, so the Microphone grant is
  attributed to, granted to, and shown as **Oatmeal alone**. You should see
  **only one** app in System Settings ▸ Privacy & Security ▸ **Microphone** —
  Oatmeal.
- **System Audio Recording is genuinely the helper's own permission.**
  `mr-capture` performs the Core Audio process tap and embeds
  `NSAudioCaptureUsageDescription` itself, so that grant is attributed to the
  helper (as a helper of Oatmeal on the menu-bar path).
- **Denied permission → possibly-silent stream.** If you decline a prompt, the
  capture may still run, write a WAV, and look normal — but the track can be
  all silence. Verify with the "Confirm capture" section below.

### Granting / re-granting

1. Start a capture: `mr start`.
2. macOS shows the prompt(s) — choose **Allow**.
3. If a prompt never appeared (or was denied earlier):
   System Settings ▸ Privacy & Security → find the entry for **Oatmeal**
   under **Microphone** and the system-audio entry → toggle it **On**.
4. Quit and relaunch the capture (`mr stop`, then `mr start`) — permission
   changes take effect on next launch.

### Recovery: a stale or duplicate permission entry

If you previously granted Microphone to the **old** `mr-capture` helper — or
to Terminal/Shortcuts — or a stale entry for an uninstalled app is still
visible in Privacy settings, do a one-time reset and re-grant:

```sh
tccutil reset Microphone
tccutil reset Calendar
```

(You may name a bundle id instead, e.g. `tccutil reset Microphone
com.oatmeal.app`.) Then start a capture (or use **Start Recording from
Calendar…**) and **Allow** the prompt — the grant is re-recorded. Why this is
needed: TCC records are keyed by code identity and are **not** removed by
dragging the app to the Trash, which is why an uninstalled app can still
appear in Privacy settings. After the reset, confirm there is **exactly one**
entry under **Microphone** — Oatmeal.

### Calendar ("Start Recording from Calendar…")

**Start Recording from Calendar…** needs Calendar access granted to Oatmeal,
and the normal path is **prompt-first**: the first time you click the item,
macOS raises its real permission prompt — choose **Allow** and the meeting
list appears straight away, with no second click and no System Settings
detour. That prompt is also what creates the Oatmeal row in System Settings ▸
Privacy & Security ▸ **Calendars**, so the Settings pane is the **fallback**,
not the first thing to open.

If you choose **Don't Allow** (or the status is already denied), Oatmeal
shows an alert with two working buttons:

- **Open System Settings** — deep-links straight to the Calendar privacy pane
  (`x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars`),
  where you enable Oatmeal under **Calendars**.
- **Try Again** — re-checks the permission and, if you have granted it in the
  meantime, continues straight to the meeting list without re-opening the
  menu.

Two non-standard states are handled explicitly:

- **Write-only grant** — a write-only Calendar status cannot list events, but
  it *can* be upgraded, so Oatmeal re-requests full access on its own; you
  should see the prompt again and can choose **Allow**. (Older builds
  silently reported this state as "denied".)
- **Restricted** — a management profile or parental controls has blocked
  Calendar access. This cannot be granted on that Mac; the alert says so and
  deliberately does **not** offer "Open System Settings", because going there
  would not help.

Note that on macOS 14+ `EKEventStore.requestFullAccessToEvents()` requires the
app bundle to declare **`NSCalendarsFullAccessUsageDescription`** — the legacy
`NSCalendarsUsageDescription` alone is not enough — so a build missing that
key will not list calendar events even if the grant looks present. Signed
hardened-runtime builds also require the `com.apple.security.personal-information.calendars`
entitlement on Oatmeal itself; without it macOS suppresses the permission prompt
and Oatmeal never appears in the Calendars settings list. Granting
Calendar to Oatmeal is what makes the calendar start path work; the plain
**Start Recording** item works without it.

### Confirming capture actually has audio

`mr doctor` does **not** check permissions (it does not pre-flight the grant
before recording; it reports the level the latest recording actually captured
— see below). After a short test recording, check the session folder
(`~/Meetings/recordings/<stamp>/`):

- `meta.json` → `mic.peak` / `mic.rms` (and `system.peak` / `system.rms`): the
  measured audio levels. A silent mic track has `peak` of `0`. (Recordings made
  before these fields existed have **no** `peak` / `rms` — use
  `samples_written` for those.)
- `meta.json` → `mic.samples_written` and `system.samples_written`: both should
  be large (thousands+ per second of recording). Near-zero ⇒ that track was
  silent (permission denied or wrong device).
- `.capture.log` → the helper logs lines like `mic level: peak 25884
  rms 0.0604`, and prints
  `warning: mic track is SILENT (all samples zero) — check Microphone permission
  for Oatmeal in System Settings, Privacy and Security` when a stream delivered
  data that was entirely zero.
- `mic.wav` / `system.wav` file sizes: silence produces near-empty WAVs.
- `mr status` shows the active session and `out_dir` while recording.

A transcript generated from a recording with a silent mic carries a header
line: `- **Warning:** the microphone track is silent (all samples zero). ...`.

## What `mr doctor` does (honest scope)

`mr doctor` checks:

- **macOS version** (the system-audio tap needs macOS 14.2+),
- **helper binary** — `mr-capture` present at `MR_CAPTURE_BIN` or the default
  `capture/.build/release/mr-capture`; otherwise prints
  `helper: MISSING (build capture/ or set MR_CAPTURE_BIN)`,
- **model cache** — whether the configured mlx-whisper model is in the local
  Hugging Face cache,
- **mic level of the latest recording** — if the latest recording's `meta.json`
  has measured `peak` / `rms` fields, it prints exactly one of:
  - `mic: SILENT in the latest recording (<stamp>) — check Microphone permission for Oatmeal in System Settings ▸ Privacy & Security`
  - `mic: ok in the latest recording (<stamp>) — peak <n> rms <n.nnnn>`
  - `mic: not measured in the latest recording (<stamp>) — re-record to confirm` (recordings made before this field existed have no level data and cannot be diagnosed retroactively)
  - `mic: unknown (no recording found)`

It does **not** check: microphone / system-audio TCC permissions directly (it
reports the audio level the latest recording actually captured; it does not
pre-flight the grant before recording), network connectivity (except via
`--fetch-model`), or that your audio device is sane. Use the WAV-size /
`meta.json` check above to confirm real capture.

## Troubleshooting

### `helper: MISSING` / "install mr-capture (MR_CAPTURE_BIN) or build the Swift package"

The Swift helper isn't built where the CLI looks for it.

```sh
cd capture && ./build.sh       # or: bash capture/install.sh
mr doctor                      # should now show "helper: capture/.build/release/mr-capture"
```

Installed it elsewhere? `export MR_CAPTURE_BIN=/path/to/mr-capture`.

### Exit code 3: "model … is not in the local HF cache (offline mode)"

Transcription at call time is **cache-only** (offline). The model was never
downloaded. Fix:

```sh
mr doctor --fetch-model        # downloads it once (network); exit 1 on failure
mr stop                        # retry — the state was kept precisely so you can
```

`mr doctor --fetch-model` exits `1` with an error if the download itself
fails (network / Hugging Face issue); check connectivity and retry.

### No audio in `mic.wav` or `system.wav` (silence)

Most likely a **denied permission** (see above) — the stream runs but delivers
silence. `mr doctor` reports the mic level of the latest recording
(`mic: SILENT …` vs `mic: ok …`); you can also check `meta.json` `mic.peak` /
`samples_written` for that track. Then grant the permission and restart the
capture. Also make sure the intended input device is selected in System
Settings ▸ Sound during the call.

### Oatmeal isn't listed in System Settings ▸ Privacy & Security ▸ Calendars

macOS only creates a Calendars row after it records a permission decision. If
no prompt appears and the app is absent, check that the signed Oatmeal build
contains the Calendar entitlement described above. A missing entitlement
prevents prompting; resetting TCC or opening Settings cannot fix that build.
With a correctly signed app, a missing row means the app has not requested
access yet. Then:

1. Click **Start Recording from Calendar…** and **Allow** the prompt — the
   row appears (and the meeting list opens straight away).
2. Still missing? Use the Calendars pane's **+** button to add the app
   manually.
3. Nuclear option: `tccutil reset Calendar`, then re-trigger **Start
   Recording from Calendar…** — the prompt appears again and the grant is
   re-created.

### Only one side (You *or* Them) appears in the transcript

Attribution is **stream-based**: whatever was in `mic.wav` becomes *You*,
whatever was in `system.wav` becomes *Them*. One side missing means that
track's audio was silent or absent:

- Check `meta.json`: the silent track's `samples_written` will be ~0.
- Check the matching permission (Microphone for `mic`, system-audio for
  `system`) — see the table above.
- Take the call on **speakers**, not a headset/earbuds — a headset routes the
  far side out of your speakers, so the system tap hears nothing.

### `mr stop` says "not recording" but I thought I was

- Run `mr status`. If it says `recording: no`, the state is genuinely clear —
  the helper may have already stopped/crashed.
- If it shows `stale pidfile; run \`mr stop\` to clear`: the helper process
  died but the state file (`~/Meetings/.state/recording.json`) was left
  behind. `mr stop` will transcribe the WAVs that exist and clear the state.
- Check `recordings/<stamp>/` for the WAVs before re-running `mr start`.

### Transcription feels slow

Both tracks are transcribed **sequentially** (mic, then system) on the local
MLX stack. Speed scales with audio length; silence is trimmed by VAD, so a
quiet call is faster than a wall-to-wall talk. This is expected — there is no
parallel/remote path by design (local-first).

### `mr start` says "already recording (stamp …)"

A session is already active (state file present and pid alive). Either `mr
stop` to finish it, or check `mr status` for where it's writing.

### Where do outputs go?

- Recordings: `~/Meetings/recordings/<stamp>/` (`mic.wav`, `system.wav`,
  `meta.json`)
- Transcripts: `~/Meetings/transcripts/<stamp>.md` (+ `.json` with `--json`)
- State: `~/Meetings/.state/recording.json`

Change the root with `out_root` in `~/.config/mr/config.toml`.
