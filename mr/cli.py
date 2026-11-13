"""`mr` command-line interface (typer app).

Exposes the full captured pipeline from the terminal:

- ``process``: transcribe an existing ``--mic``/``--system`` WAV pair and
  write the attributed Markdown transcript (plus optional JSON sidecar).
- ``start``: spawn ``mr-capture`` (long-lived; outlives this command) and
  record the pidfile state.
- ``status``: is a capture active? plus the most recent transcript.
- ``stop``: SIGINT the capture, wait briefly for its WAVs, clear state,
  and spawn ``mr _transcribe`` as a detached background process
  (transcription + notification happen after ``mr stop`` returns).
- ``toggle``: start if idle/stale, else stop.
- ``doctor``: environment check (macOS version, helper binary, model cache);
  ``--fetch-model`` pre-downloads the Whisper model.

The long-lived spawn in ``start`` deliberately does NOT use
``RecordSession`` (its ``__exit__`` reaps/signals the child); instead the
binary is spawned via ``subprocess.Popen`` and only the PID is persisted.
"""

from __future__ import annotations

import json
import multiprocessing
import os
import platform
import signal
import subprocess
import sys
import threading
import time
import traceback
from datetime import UTC, datetime
from pathlib import Path
from typing import Annotated

import typer

from mr.config import Config, load_config, set_out_root
from mr.core.capture import assert_capture_bin
from mr.core.diarize import DEFAULT_DIARIZATION_MODEL, assign_speakers, diarize_audio
from mr.core.merge import merge_transcripts, shift_segments
from mr.core.output import (
    render_transcript_json,
    render_transcript_md,
    write_json,
    write_transcript,
)
from mr.core.schema import CaptureMeta, Segment, from_capture_dict, is_silent_stream
from mr.core.transcribe import (
    DEFAULT_MODEL,
    ModelNotCachedError,
    limit_mlx_cache,
    release_whisper_model,
    transcribe_audio,
)
from mr.heartbeat import (
    clear_transcribing_heartbeat,
    read_transcribing_heartbeat,
    touch_transcribing_heartbeat,
    write_transcribing_heartbeat,
)
from mr.state import clear_state, is_clear, is_stale, new_stamp, read_state, write_state

app = typer.Typer(help="Local-first meeting recorder: capture and transcribe 1:1 calls.")

#: Per-recording log file holding the detached ``mr _transcribe`` worker's
#: stdout/stderr. Lives next to the WAVs so a failure is diagnosable from the
#: recording dir alone.
TRANSCRIBE_LOG_NAME = ".transcribe.log"

#: Why this worker run should abort, or ``None`` for a normal run. Set ONLY by the
#: ``_transcribe --reason`` CLI option; read by :func:`_write_failed_stub`.
_STOP_REASON: str | None = None

#: Stub filename suffix written when a run was stopped by the user.
STOPPED_STUB_SUFFIX = ".STOPPED.md"

#: How long the cancelled worker gets to exit before we stop waiting. SIGTERM
#: terminates the process immediately (no handler is installed), but the
#: process entry can be reaped slightly later; a tracked background job gets
#: its own grace period, so we wait inside the budget rather than reporting a
#: kill we cannot yet confirm.
TRANSCRIBE_LINGER_SECONDS = 120.0

#: Reason string written into the worker's ``.STOPPED.md`` stub when the stop
#: command kills it.
STOP_REASON_TEXT = "mr stop-transcribe"


@app.callback()
def _root() -> None:
    """Keep the app multi-command (typer collapses single-command apps)."""
    return None


# ---------------------------------------------------------------------------
# Private helpers (shared by the start/stop/toggle commands; monkeypatchable)
# ---------------------------------------------------------------------------


def _spawn_capture(out_dir: str, binary: str, log_path: Path | None = None) -> int:
    """Spawn the (long-lived) ``mr-capture`` helper and return its PID.

    The child must outlive this short-lived CLI process, so it is started
    with ``subprocess.Popen`` and not reaped here; the PID is persisted to
    the state pidfile by the caller.

    The child's stdio is redirected to ``<out_dir>/.capture.log`` and the
    process is detached with ``start_new_session=True``, so ``mr start``
    never blocks on the child's pipes (a menu-bar app reading ``mr start``'s
    stdout sees EOF as soon as ``mr start`` exits, even though
    ``mr-capture`` keeps running).
    """
    log_path = log_path or (Path(out_dir) / ".capture.log")
    log_fh = open(log_path, "a", encoding="utf-8")
    p = subprocess.Popen(
        [binary, "--out", out_dir],
        stdout=log_fh,
        stderr=log_fh,
        start_new_session=True,
    )
    log_fh.close()  # Popen dup'd the fd into the child
    return p.pid


def _spawn_transcription(stamp: str, out_dir: str, *, json_sidecar: bool = False) -> bool:
    """Spawn ``mr _transcribe`` as a detached background process (MB-BG/B2).

    The child runs in its own session (``start_new_session=True``) so it
    outlives this short-lived CLI and ``mr stop`` returns immediately. The
    worker owns the transcription heartbeat and the completion notification.
    Returns ``True`` if the process was spawned.

    The child's stdout/stderr go to ``<out_dir>/.transcribe.log`` (same
    pattern as :func:`_spawn_capture`): a worker that dies — OOM, corrupt
    WAV, mlx crash — must leave a trace, otherwise a silent failure and a
    slow success are indistinguishable. ``stdin`` stays ``DEVNULL``.

    When frozen (PyInstaller), ``sys.executable`` IS the ``mr-cli`` binary, so
    the ``-m mr.cli`` prefix is dropped (it would be parsed as an unknown
    option by the frozen CLI).
    """
    frozen = getattr(sys, "frozen", False)
    if frozen:
        # Frozen (PyInstaller): sys.executable IS the mr CLI; do not prepend
        # `-m mr.cli` (which the frozen binary treats as an unknown option).
        args = [sys.executable, "_transcribe", stamp, out_dir]
    else:
        args = [sys.executable, "-m", "mr.cli", "_transcribe", stamp, out_dir]
    if json_sidecar:
        args.append("--json")
    try:
        log_fh = open(Path(out_dir) / TRANSCRIBE_LOG_NAME, "a", encoding="utf-8")
    except OSError:
        # A missing/unwritable out_dir must not stop transcription; fall back
        # to discarding the child's output rather than not spawning it.
        log_fh = None
    try:
        subprocess.Popen(
            args,
            stdin=subprocess.DEVNULL,
            stdout=log_fh or subprocess.DEVNULL,
            stderr=subprocess.STDOUT if log_fh else subprocess.DEVNULL,
            start_new_session=True,
        )
    except OSError:
        return False
    finally:
        if log_fh is not None:
            log_fh.close()  # Popen dup'd the fd into the child
    return True


def _recordings_dir(cfg: Config) -> Path:
    """Root directory holding per-session recording dirs."""
    return Path(cfg.out_root) / "recordings"


def _transcripts_dir(cfg: Config) -> Path:
    """Directory holding the final ``<stamp>.md`` transcripts."""
    return Path(cfg.out_root) / "transcripts"


def _diarize_system(segments: list[Segment], wav: Path, model: str) -> list[Segment]:
    """Relabel system-track ``segments`` as ``Speaker 1..N``; fail-soft.

    Runs on ``system.wav``'s own timeline, so callers must call this BEFORE
    ``shift_segments``. Any failure (model not cached, mlx-audio missing or
    broken, bad audio) logs a warning to stderr — the worker's
    ``.transcribe.log`` — and returns ``segments`` unchanged, so the
    transcript falls back to a single ``Them`` and never fails because of
    diarization.
    """
    try:
        turns = diarize_audio(str(wav), model=model)
        return assign_speakers(segments, turns)
    except Exception as e:  # noqa: BLE001 - diarization must never sink a transcript
        typer.echo(
            f"warning: diarization failed ({type(e).__name__}: {e}); "
            "remote speakers left as 'Them'",
            err=True,
        )
        traceback.print_exc()  # to stderr -> .transcribe.log, for diagnosis
        return list(segments)


def _transcribe_and_write(
    cfg: Config, stamp: str, out_dir: str, *, json_sidecar: bool = False
) -> Path:
    """Transcribe both WAVs in ``out_dir``, merge, and write the transcript.

    Returns the path of the written ``transcripts/<stamp>.md``.
    Raises :class:`~mr.core.transcribe.ModelNotCachedError` when the model
    is not cached (callers decide the exit code / state handling).
    """
    o = Path(out_dir)
    you = transcribe_audio(
        str(o / "mic.wav"), speaker="You", model=cfg.model, language=cfg.language
    )
    them = transcribe_audio(
        str(o / "system.wav"), speaker="Them", model=cfg.model, language=cfg.language
    )
    # Whisper is done: free its weights + MLX cache before diarization loads.
    release_whisper_model()
    # The two WAVs each start at their own first sample, so they must be put
    # on one timeline before the overlap-based echo rule can see an echo and
    # its original as concurrent. See _stream_start_offsets.
    them_raw = list(them.segments)
    if cfg.diarize:
        # Before the shift: the diarizer's turns are on system.wav's timeline.
        them_raw = _diarize_system(them_raw, o / "system.wav", cfg.diarization_model)
    mic_offset, system_offset = _stream_start_offsets(o)
    you_segments = shift_segments(list(you.segments), mic_offset)
    them_segments = shift_segments(them_raw, system_offset)
    merged = merge_transcripts(
        you_segments,
        them_segments,
        dedup_threshold=cfg.dedup_threshold,
    )
    duration = max((s.end for s in you_segments + them_segments), default=0.0)
    context = _read_meeting_context(o)
    capture = _read_capture_meta(o)
    md_path = _transcripts_dir(cfg) / f"{stamp}.md"
    write_transcript(
        md_path,
        render_transcript_md(
            stamp=stamp,
            source_dir=f"recordings/{stamp}",
            segments=merged,
            duration_seconds=duration,
            context=context,
            capture=capture,
        ),
    )
    if json_sidecar:
        write_json(
            md_path.with_suffix(".json"),
            render_transcript_json(merged, stamp=stamp, context=context),
        )
    return md_path


def _read_meeting_context(out_dir: Path) -> dict[str, object] | None:
    """Load ``meeting_context.json`` from ``out_dir`` if present.

    Returns the parsed dict, or ``None`` when the file is missing,
    malformed, or not a JSON object. Never raises.
    """
    try:
        parsed = json.loads((out_dir / "meeting_context.json").read_text(encoding="utf-8"))
    except (OSError, ValueError, TypeError):
        return None
    return parsed if isinstance(parsed, dict) else None


def _stream_start_offsets(out_dir: Path) -> tuple[float, float]:
    """Return ``(mic_offset, system_offset)`` seconds aligning the two tracks.

    ``mr-capture`` starts the mic and the system tap independently and each
    WAV begins at its own first sample, so the two files share no timeline:
    on ``2026-10-20_1553`` the system tap started 10.49 s after the mic, which
    shifted every ``Them`` timestamp that much earlier than reality. The
    stream that started *later* is the one missing time at its head, so it
    gets the positive delta and the earlier stream gets ``0.0``.

    Fail-soft: a missing, malformed, or incomplete ``meta.json`` yields
    ``(0.0, 0.0)``. An unknown offset must shift nothing rather than guess —
    a wrong shift is worse than the misalignment it tries to correct.
    """
    try:
        parsed = json.loads((out_dir / "meta.json").read_text(encoding="utf-8"))
        meta = from_capture_dict(parsed)
    except (OSError, ValueError, TypeError, KeyError):
        return (0.0, 0.0)
    delta = meta.system.first_sample_seconds - meta.mic.first_sample_seconds
    if delta > 0:
        return (0.0, delta)  # system tap started late; push Them forward
    return (-delta, 0.0)  # mic started late (or dead even); push You forward


def _read_capture_meta(out_dir: Path) -> CaptureMeta | None:
    """Load ``meta.json`` from a recording dir; ``None`` when missing/invalid.

    Fail-soft like :func:`_stream_start_offsets`: a missing, unreadable, or
    malformed ``meta.json`` yields ``None`` rather than raising, so the
    transcript is still written (without the silent-track warning).
    """
    try:
        parsed = json.loads((out_dir / "meta.json").read_text(encoding="utf-8"))
        return from_capture_dict(parsed)
    except (OSError, ValueError, TypeError, KeyError):
        return None


def _latest_recording_meta(out_root: str) -> tuple[str, CaptureMeta] | None:
    """Newest <out_root>/recordings/<stamp> with a readable meta.json, or None.

    Stamps sort lexicographically by time, so the newest recording is the
    greatest directory name. If that newest directory's meta.json is missing or
    malformed we return ``None`` rather than falling back to an older recording:
    the line `mr doctor` prints is about the LATEST recording, so silently
    reporting an older one would mislead the user.
    """
    try:
        recs = sorted(p for p in (Path(out_root) / "recordings").iterdir() if p.is_dir())
        if not recs:
            return None
        newest = recs[-1]
    except OSError:
        return None
    meta = _read_capture_meta(newest)
    if meta is None:
        return None
    return (newest.name, meta)


def _write_failed_stub(cfg: Config, stamp: str, out_dir: str, error: BaseException) -> Path | None:
    """Write ``transcripts/<stamp>.FAILED.md`` describing a failed transcription.

    The background worker is detached, so a crash is otherwise invisible: the
    heartbeat just ages out and no transcript ever appears. This drops a
    marker in the directory the user actually watches, pointing at the
    worker log for the traceback. Fail-soft — returns ``None`` if the stub
    itself cannot be written (never masks the original error).
    """
    path = _transcripts_dir(cfg) / f"{stamp}.FAILED.md"
    cancelled = _STOP_REASON is not None
    if cancelled:
        # A user-cancelled run is not a failure: it must not be reported as one
        # (no FAILED.md marker, no "transcription failed" notification), and an
        # aborted run must not leave a partial transcript behind either.
        path = _transcripts_dir(cfg) / f"{stamp}{STOPPED_STUB_SUFFIX}"
        for stale in (f"{stamp}.FAILED.md", f"{stamp}.md"):
            try:
                (_transcripts_dir(cfg) / stale).unlink(missing_ok=True)
            except OSError:
                pass
    log_path = Path(out_dir) / TRANSCRIBE_LOG_NAME
    lines = [
        f"# Transcription stopped — {stamp}" if cancelled else f"# Transcription FAILED — {stamp}",
        "",
        f"- **Recording:** {out_dir}",
        f"- **Error:** {type(error).__name__}: {error}",
    ]
    if cancelled:
        lines.append(f"- **Stopped:** transcription was cancelled ({_STOP_REASON})")
    # The log only exists when the worker was spawned by `_spawn_transcription`
    # (which creates it); running `mr _transcribe` by hand writes to the
    # terminal instead. Don't point the user at a file that isn't there.
    if log_path.is_file():
        lines.append(f"- **Log:** {log_path}")
    lines += [
        "",
        "The audio is intact. Re-run the transcription with:",
        "",
        "```sh",
        f"mr _transcribe {stamp} {out_dir}",
        "```",
    ]
    text = "\n".join(lines)
    try:
        write_transcript(path, text)
    except OSError:
        return None
    return path


#: How often the worker refreshes its heartbeat's ``updated_at``. Well inside
#: ``mr.heartbeat.DEFAULT_MAX_AGE_SECONDS`` (300 s), so a live worker never
#: reads as stale; previously the heartbeat was written once and a run longer
#: than 5 min disappeared from the menu, `stop-transcribe` could not find it,
#: and `retranscribe` could start a second worker on the same stamp.
HEARTBEAT_REFRESH_SECONDS = 30.0


def _start_heartbeat_refresher(
    out_root: str, stamp: str, pid: int, interval: float = HEARTBEAT_REFRESH_SECONDS
) -> threading.Event:
    """Refresh the heartbeat every ``interval`` s on a daemon thread.

    Returns the stop event; set it to end the thread. The touch only rewrites
    a heartbeat this worker (stamp + pid) still owns, so it never recreates a
    cleared one or overwrites a newer worker's.
    """
    stop = threading.Event()

    def _run() -> None:
        while not stop.wait(interval):
            touch_transcribing_heartbeat(out_root, stamp, pid)

    threading.Thread(target=_run, name="mr-heartbeat", daemon=True).start()
    return stop


def _transcribe_worker(
    cfg: Config, stamp: str, out_dir: str, *, json_sidecar: bool = False
) -> Path:
    """Transcribe ``out_dir`` with a heartbeat around it (MB-BG background worker).

    Writes the transcription heartbeat, transcribes + writes
    ``transcripts/<stamp>.md`` (plus optional JSON sidecar), and clears the
    heartbeat in ``finally`` — so the success path AND every failure path
    remove it.

    Any failure also writes ``transcripts/<stamp>.FAILED.md`` and exits
    non-zero (3 for :class:`~mr.core.transcribe.ModelNotCachedError`, 1
    otherwise): a detached worker that dies silently is indistinguishable
    from one still running. When ``cfg.keep_audio`` is false the WAVs are
    deleted afterwards — only on success, so a retry still has its audio.
    """
    utc_now = datetime.now(UTC).isoformat().replace("+00:00", "Z")
    # Bound MLX's buffer cache for the whole worker: uncapped it reached ~10 GB
    # and pushed the worker into swap on a busy machine (looked like a hang).
    limit_mlx_cache()
    # A cancelled predecessor may not have run its `finally` yet; the pid match
    # makes this clear address THAT worker's heartbeat, never a different one.
    clear_transcribing_heartbeat(cfg.out_root, stamp, pid=os.getpid())
    write_transcribing_heartbeat(cfg.out_root, stamp, utc_now, pid=os.getpid())
    refresher = _start_heartbeat_refresher(cfg.out_root, stamp, os.getpid())
    try:
        md = _transcribe_and_write(cfg, stamp, out_dir, json_sidecar=json_sidecar)
    except ModelNotCachedError as e:
        typer.echo(f"error: {e}", err=True)
        _write_failed_stub(cfg, stamp, out_dir, e)
        raise typer.Exit(code=3) from e
    except Exception as e:
        # Anything else (corrupt WAV, mlx crash, OOM-adjacent errors): the
        # traceback goes to the worker log via stderr, the stub goes where
        # the user will see it.
        typer.echo(f"error: transcription failed for {stamp}: {e}", err=True)
        traceback.print_exc()
        _write_failed_stub(cfg, stamp, out_dir, e)
        raise typer.Exit(code=1) from e
    finally:
        refresher.set()  # stop refreshing before the clear
        # The pid match keeps a late `finally` from clobbering a newer
        # worker's heartbeat for the same stamp.
        clear_transcribing_heartbeat(cfg.out_root, stamp, pid=os.getpid())

    # A successful (re-)run clears any marker left by an earlier failure, so
    # the transcripts dir never shows a transcript and a FAILED stub for the
    # same stamp.
    for stale in (f"{stamp}.FAILED.md", f"{stamp}{STOPPED_STUB_SUFFIX}"):
        (_transcripts_dir(cfg) / stale).unlink(missing_ok=True)

    if not cfg.keep_audio:
        for name in ("mic.wav", "system.wav"):
            (Path(out_dir) / name).unlink(missing_ok=True)

    return md


def _fetch_model(model: str) -> None:
    """Download ``model`` into the standard HF hub cache (network allowed).

    ``huggingface_hub`` is imported lazily, only on this path.
    """
    import huggingface_hub  # lazy: only used with `doctor --fetch-model`

    huggingface_hub.snapshot_download(repo_id=model)


def _model_cached(model: str) -> bool:
    """Best-effort check that ``model`` is present in the local HF cache.

    Prefers ``huggingface_hub.scan_cache_dir`` (guarded import); falls back
    to checking for ``models--<repo with '/'→'--'>`` under
    ``~/.cache/huggingface/hub`` when the package is absent.
    """
    try:
        from huggingface_hub import scan_cache_dir

        return any(repo.repo_id == model for repo in scan_cache_dir().repos)
    except ImportError:
        repo_dir = "models--" + model.replace("/", "--")
        return (Path.home() / ".cache" / "huggingface" / "hub" / repo_dir).is_dir()


def _do_start(cfg: Config, context_json: Path | None = None) -> None:
    """Start a capture (shared by ``start`` and ``toggle``).

    ``context_json`` is an optional path to a JSON file (title/attendees/
    notes) whose raw text is persisted as ``meeting_context.json`` inside the
    freshly-created recording dir, so a later transcription step can read it.
    """
    if not is_clear(cfg.out_root):
        state = read_state(cfg.out_root)
        stamp = state.stamp if state is not None else "?"
        out_dir = state.out_dir if state is not None else "?"
        typer.echo(f"already recording (stamp {stamp}, out_dir {out_dir})")
        return

    stamp = new_stamp()
    out_dir = _recordings_dir(cfg) / stamp
    out_dir.mkdir(parents=True, exist_ok=True)
    if context_json is not None:
        msg = f"--context-json file not found or invalid: {context_json}"
        try:
            raw = context_json.read_text(encoding="utf-8")
        except OSError as e:
            raise typer.BadParameter(msg) from e
        try:
            json.loads(raw)
        except json.JSONDecodeError as e:
            raise typer.BadParameter(msg) from e
        (out_dir / "meeting_context.json").write_text(raw, encoding="utf-8")
    binary = assert_capture_bin()
    pid = _spawn_capture(str(out_dir), binary)
    write_state(cfg.out_root, pid, str(out_dir), stamp, datetime.now().isoformat())
    typer.echo(f"recording started (stamp {stamp})\nout_dir: {out_dir}")


def _do_stop(cfg: Config, json_sidecar: bool) -> None:
    """Stop the capture, clear state, and transcribe in the background.

    Shared by ``stop`` and ``toggle``. Signals ``mr-capture`` (SIGINT),
    waits briefly for its WAVs to flush, clears the recording state, spawns
    the hidden ``mr _transcribe`` worker as a detached background process,
    and returns immediately (~1-2 s). The background worker owns the
    transcription heartbeat and the completion notification; on
    :class:`ModelNotCachedError` it exits with code 3, while ``mr stop``
    itself stays exit 0 so a new recording can start right away.
    """
    state = read_state(cfg.out_root)
    if state is None:
        typer.echo("not recording")
        return

    if not is_stale(state):
        try:
            os.kill(state.pid, signal.SIGINT)
        except ProcessLookupError:
            pass  # child already gone between is_stale() and kill()
        # Give the helper up to ~15 s to flush its WAVs + meta.json.
        needed = ("mic.wav", "system.wav", "meta.json")
        deadline = time.monotonic() + 15.0
        while time.monotonic() < deadline and not all(
            (Path(state.out_dir) / name).is_file() for name in needed
        ):
            time.sleep(0.25)

    out_path = Path(state.out_dir)
    if not out_path.is_dir() or not all(
        (out_path / name).is_file() for name in ("mic.wav", "system.wav")
    ):
        # Recorded files are gone (deleted, or a crash before they flushed):
        # nothing to transcribe — clear the stale pid and finish cleanly.
        clear_state(cfg.out_root)
        typer.echo(f"recorded files missing for {state.stamp}; cleared stale recording state")
        return

    # Transcription runs in a detached background process: the worker owns
    # the heartbeat and the completion notification (and exits 3 on
    # ModelNotCachedError), so this command never blocks on it.
    spawned = _spawn_transcription(state.stamp, state.out_dir, json_sidecar=json_sidecar)
    # Clear state ALWAYS — a new recording must be possible even if the
    # background spawn failed.
    clear_state(cfg.out_root)
    if spawned:
        typer.echo(f"stopped recording {state.stamp} — transcribing in the background")
    else:
        typer.echo("stopped recording; error: could not start background transcription", err=True)


def _notify_transcription_stopped(stamp: str) -> None:
    """Post a best-effort "transcription stopped" user notification.

    Never raises, never blocks. Lives here (not in the app) because the
    command can be run from the terminal as well as the app, and posting it
    in the one place that performs the kill means the notification is never
    duplicated. Same mechanism the repo used before the app moved to
    ``UNUserNotificationCenter`` (see
    ``menu-bar/Sources/Oatmeal/TranscriptNotifier.swift`` for the history).
    """
    script = f'display notification "Transcription of {stamp} was stopped." with title "Oatmeal"'
    try:
        subprocess.run(["osascript", "-e", script], check=False, capture_output=True)
    except Exception:
        return


def _do_stop_transcribe(cfg: Config, stamp: str | None = None) -> int:
    """Stop the in-flight background transcription and say what happened.

    Finds the transcribing worker via the heartbeat, signals exactly that
    PID (plain SIGTERM; the worker installs no handler, so it dies
    immediately), waits up to :data:`TRANSCRIBE_LINGER_SECONDS` for the
    process entry to disappear, and clears the heartbeat — clearing the
    file is exactly the "cancelled" signal the worker's own ``finally`` also
    set out to produce. Returns a process exit code: 0 on success or
    nothing-to-do, 1 when the heartbeat has no usable PID.
    """
    hb = read_transcribing_heartbeat(cfg.out_root)
    if hb is None:
        typer.echo("no transcription running")
        return 0

    active = hb.get("stamp")
    if stamp is not None and stamp != active:
        typer.echo(f"no transcription running for {stamp}")
        return 0

    pid = hb.get("pid")
    if not isinstance(pid, int) or isinstance(pid, bool):
        typer.echo(f"cannot stop {active}: heartbeat has no pid", err=True)
        return 1

    def _pid_gone() -> bool:
        """True if the PID is gone (``os.kill(pid, 0)`` finds no process).

        Mirrors ``mr.state.is_stale``: only ``ProcessLookupError`` means
        gone (a ``PermissionError`` from a sandboxed caller means alive).
        A zombie still answers ``os.kill(pid, 0)``, so this alone cannot
        tell an exited-but-unreaped child from a running worker.
        """
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return True
        except OSError:
            return False
        return False

    def _reapable_relative() -> int | None:
        """PID of a child of ours that has exited but is not yet reaped.

        A zombie still answers ``os.kill(pid, 0)``, so a liveness probe alone
        cannot tell it from a running worker — and calling SIGTERM on it would
        report success for a process that was already gone. ``ps`` answers this
        on macOS but cannot be executed in every environment (a sandboxed shell
        gets EPERM), so the check is done with ``waitpid`` instead: a grandchild
        raises ``ChildProcessError`` (not ours — treat it as running and let the
        signal path decide), while our own exited child is reported here.
        """
        try:
            reaped_pid, _ = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            return None
        except OSError:
            return None
        return pid if reaped_pid else None

    if _pid_gone() or _reapable_relative() is not None:
        clear_transcribing_heartbeat(cfg.out_root, active, pid=pid)
        typer.echo(f"{active} already finished")
        return 0

    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        # Raced to death between the checks and the kill: same calm outcome.
        clear_transcribing_heartbeat(cfg.out_root, active, pid=pid)
        typer.echo(f"{active} already finished")
        return 0

    # Wait for the process to disappear (poll every 0.1 s inside the budget).
    # An exited child of ours is reported by ``_reapable_relative()`` (which
    # reaps it); a dead non-child PID is reported by the ``_pid_gone()`` probe.
    deadline = time.monotonic() + TRANSCRIBE_LINGER_SECONDS
    while True:
        if time.monotonic() >= deadline:
            break
        reaped = _reapable_relative()
        if reaped is not None or _pid_gone():
            break
        time.sleep(0.1)

    # The PID match makes this safe even if the worker already replaced its
    # own heartbeat (a re-transcribe of the same stamp).
    clear_transcribing_heartbeat(cfg.out_root, active, pid=pid)
    typer.echo(f"stopped transcription of {active}")
    _notify_transcription_stopped(active)
    return 0


def _do_retranscribe(
    cfg: Config, stamp: str, *, out_dir: str | None = None, json_sidecar: bool = False
) -> int:
    """Re-run the transcription of an existing recording (RT-4).

    The recording directory is derived HERE — never by the caller — so the
    CLI stays the single source of truth for the on-disk layout
    (``<out_root>/recordings/<stamp>/``). ``out_dir`` exists purely as a test
    seam; the Swift/menu-bar caller never passes it.

    The WAVs are the precondition: a recording is transcribable only while
    BOTH ``mic.wav`` and ``system.wav`` exist. When ``keep_audio`` is false,
    ``stop`` deletes the WAVs after a successful transcription, so a later
    re-transcribe simply has no audio left to re-read — refuse rather than
    spawn a worker that is guaranteed to fail.

    A fresh heartbeat for the same stamp means a live worker owns this
    recording: never start a second one over a running one.

    The worker is spawned detached (exactly like ``mr stop``), so the caller
    returns immediately while transcription continues in the background.

    The existing ``transcripts/<stamp>.md`` is deliberately NOT deleted or
    truncated: the worker overwrites it on success, and a user's transcript
    must never disappear because a re-run was attempted.

    Returns a process exit code: 0 on successful spawn, 1 on validation or
    spawn failure. All stdout output is plain one-line text (never a typer
    Table/Panel — auto-detected ANSI would corrupt the caller's parsing).
    """
    rec = Path(out_dir) if out_dir is not None else _recordings_dir(cfg) / stamp
    if not rec.is_dir():
        typer.echo(f"no recording directory for {stamp}: {rec}", err=True)
        return 1
    if not (rec / "mic.wav").is_file() or not (rec / "system.wav").is_file():
        # keep_audio deletes the WAVs after a successful transcription;
        # without both, there is no audio left to transcribe.
        typer.echo(f"recording {stamp} has no audio left (mic.wav/system.wav missing)", err=True)
        return 1
    hb = read_transcribing_heartbeat(cfg.out_root)
    if hb is not None and hb.get("stamp") == stamp:
        typer.echo(f"{stamp} is already transcribing", err=True)
        return 1
    if not _spawn_transcription(stamp, str(rec), json_sidecar=json_sidecar):
        typer.echo("error: could not start background transcription", err=True)
        return 1
    typer.echo(f"retranscribing {stamp}")
    return 0


def _do_config_set(key: str, value: str) -> None:
    """Apply ``config set <key> <value>`` (v1.1: only ``out_root``).

    Raises :class:`typer.BadParameter` for an unsupported key or an invalid
    value (typer reports it and exits 2).
    """
    if key != "out_root":
        raise typer.BadParameter(f"unsupported config key: {key!r}")
    try:
        new_root = set_out_root(value)
    except ValueError as e:
        raise typer.BadParameter(str(e)) from e
    typer.echo(f"out_root: {new_root}")


def _do_config_get(key: str) -> None:
    """Print ``config get <key>`` (v1.1: only ``out_root``).

    Raises :class:`typer.BadParameter` for an unsupported key (typer reports
    it and exits 2).
    """
    if key != "out_root":
        raise typer.BadParameter(f"unsupported config key: {key!r}")
    cfg = load_config()
    typer.echo(cfg.out_root)


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------


@app.command()
def process(
    mic: Annotated[Path, typer.Option("--mic", help="You-side 16 kHz mono mic WAV")],
    system: Annotated[
        Path, typer.Option("--system", help="Them-side 16 kHz mono system WAV")
    ],
    model: Annotated[str, typer.Option(help="HF model id")] = DEFAULT_MODEL,
    language: Annotated[str, typer.Option(help="Language code")] = "en",
    dedup_threshold: Annotated[
        float, typer.Option("--dedup-threshold", min=0.0, max=1.0)
    ] = 0.6,
    json: Annotated[bool, typer.Option("--json", help="Also write a JSON sidecar")] = False,
    stamp: Annotated[str, typer.Option(help="Stamp/label for the transcript")] = "",
    out_dir: Annotated[
        Path | None, typer.Option("--out-dir", help="Directory for transcript.md/json")
    ] = None,
    diarize: Annotated[
        bool,
        typer.Option(
            "--diarize/--no-diarize",
            help="Split the system side into Speaker 1..N (falls back to Them)",
        ),
    ] = True,
    diarization_model: Annotated[
        str, typer.Option("--diarization-model", help="HF diarization model id")
    ] = DEFAULT_DIARIZATION_MODEL,
) -> None:
    """Transcribe both WAVs, merge with echo dedup, and write the transcript."""
    for label, path in (("--mic", mic), ("--system", system)):
        if not path.is_file():
            raise typer.BadParameter(f"{label} file not found: {path}")

    limit_mlx_cache()
    try:
        you = transcribe_audio(str(mic), speaker="You", model=model, language=language)
        them = transcribe_audio(str(system), speaker="Them", model=model, language=language)
        release_whisper_model()
    except ModelNotCachedError as e:
        typer.echo(f"error: {e}", err=True)
        raise typer.Exit(code=3) from e

    them_segments = list(them.segments)
    if diarize:
        them_segments = _diarize_system(them_segments, system, diarization_model)
    merged = merge_transcripts(
        list(you.segments), them_segments, dedup_threshold=dedup_threshold
    )
    duration = max((s.end for s in list(you.segments) + them_segments), default=0.0)

    out = out_dir or system.parent
    stamp = stamp or system.stem
    capture = _read_capture_meta(system.parent)
    md_path = out / f"{stamp}.md"
    write_transcript(
        md_path,
        render_transcript_md(
            stamp=stamp,
            source_dir=f"recordings/{stamp}",
            segments=merged,
            duration_seconds=duration,
            capture=capture,
        ),
    )
    typer.echo(f"wrote {md_path}")
    if json:
        json_path = out / f"{stamp}.json"
        write_json(json_path, render_transcript_json(merged, stamp=stamp))
        typer.echo(f"wrote {json_path}")
    kept = sum(1 for s in merged if not s.echo_suspected)
    echoed = len(merged) - kept
    msg = f"kept {kept} segments"
    if echoed:
        # Flagged, not deleted: they are in the JSON sidecar when one was asked for.
        msg += f" ({echoed} echo-suspected, omitted from the transcript)"
    typer.echo(msg)


@app.command(hidden=True, name="_transcribe")
def transcribe_worker(
    stamp: Annotated[str, typer.Argument(help="Recording stamp (folder name)")],
    out_dir: Annotated[str, typer.Argument(help="Recording dir holding mic.wav/system.wav")],
    json: Annotated[bool, typer.Option("--json", help="Also write a JSON sidecar")] = False,
    reason: Annotated[
        str | None,
        typer.Option("--reason", help="Why this run was cancelled (internal)"),
    ] = None,
) -> None:
    """Internal: transcribe a recording dir in the background (MB-BG)."""
    global _STOP_REASON
    _STOP_REASON = reason
    cfg = load_config()
    md = _transcribe_worker(cfg, stamp, out_dir, json_sidecar=json)
    typer.echo(f"wrote {md}")
    # No notification here: this worker is a detached process with no bundle
    # identity, so an `osascript` notification was owned by Script Editor (no
    # Oatmeal branding, and clicking it opened that app). The menu-bar app
    # watches the transcripts dir and posts the notification itself — see
    # menu-bar/Sources/Oatmeal/TranscriptNotifier.swift.


@app.command()
def start(
    context_json: Annotated[
        Path | None,
        typer.Option(
            "--context-json",
            help=(
                "JSON file with meeting context (title/attendees/notes) "
                "to persist with this recording"
            ),
        ),
    ] = None,
) -> None:
    """Start recording (spawns ``mr-capture``; it keeps running after exit)."""
    _do_start(load_config(), context_json=context_json)


@app.command()
def status() -> None:
    """Show whether a capture is active and the most recent transcript."""
    cfg = load_config()
    state = read_state(cfg.out_root)
    if state is None:
        typer.echo("recording: no")
    else:
        recording = not is_stale(state)
        typer.echo(f"recording: {'yes' if recording else 'no'}")
        typer.echo(f"pid: {state.pid}")
        typer.echo(f"out_dir: {state.out_dir}")
        typer.echo(f"stamp: {state.stamp}")
        typer.echo(f"started_at: {state.started_at}")
        if not recording:
            typer.echo("stale pidfile; run `mr stop` to clear", err=True)
    tdir = _transcripts_dir(cfg)
    if tdir.is_dir():
        mds = sorted(tdir.glob("*.md"), key=lambda p: (p.stat().st_mtime, p.name))
        if mds:
            typer.echo(f"last transcript: {mds[-1]}")
        else:
            typer.echo("no transcript yet")
    else:
        typer.echo("no transcript yet")


@app.command()
def stop(
    json: Annotated[bool, typer.Option("--json", help="Also write a JSON sidecar")] = False,
) -> None:
    """Stop the capture and transcribe it in the background.

    Returns immediately (~1-2 s): transcription continues in a detached
    background process and posts a completion notification when done.
    """
    _do_stop(load_config(), json)


@app.command(name="stop-transcribe")
def stop_transcribe(
    stamp: Annotated[
        str | None,
        typer.Argument(help="Only stop if this stamp is the active transcription"),
    ] = None,
) -> None:
    """Stop the in-flight background transcription (and say what happened)."""
    raise typer.Exit(code=_do_stop_transcribe(load_config(), stamp))


@app.command()
def retranscribe(
    stamp: Annotated[str, typer.Argument(help="Recording stamp (folder name)")],
    json: Annotated[bool, typer.Option("--json", help="Also write a JSON sidecar")] = False,
) -> None:
    """Re-run the transcription of an existing recording."""
    raise typer.Exit(code=_do_retranscribe(load_config(), stamp, json_sidecar=json))


@app.command()
def toggle(
    json: Annotated[bool, typer.Option("--json", help="JSON sidecar when stopping")] = False,
) -> None:
    """Start recording if idle, otherwise stop it (transcribing in the background)."""
    cfg = load_config()
    state = read_state(cfg.out_root)
    if state is None or is_clear(cfg.out_root) or is_stale(state):
        _do_start(cfg)
    else:
        _do_stop(cfg, json)


@app.command()
def doctor(
    fetch_model: Annotated[
        bool, typer.Option("--fetch-model", help="Download the model if not cached")
    ] = False,
) -> None:
    """Check the environment: macOS version, helper binary, model cache."""
    cfg = load_config()
    typer.echo(f"macOS: {platform.mac_ver()[0] or platform.platform()}")
    typer.echo(f"out_root: {cfg.out_root}")
    try:
        typer.echo(f"helper: {assert_capture_bin()}")
    except FileNotFoundError:
        typer.echo("helper: MISSING (build capture/ or set MR_CAPTURE_BIN)")
    typer.echo(f"model: {cfg.model}")
    cached = _model_cached(cfg.model)
    typer.echo(f"model cached: {'yes' if cached else 'no'}")

    # Fail-soft: a missing/empty recordings dir or a malformed meta.json must
    # never break `mr doctor` — we just report the mic level as unknown.
    try:
        latest = _latest_recording_meta(cfg.out_root)
    except Exception:  # defensive: discovery must not raise
        latest = None
    if latest is None:
        typer.echo("mic: unknown (no recording found)")
    else:
        stamp, capture = latest
        mic = capture.mic
        if mic.peak is None:
            typer.echo(
                f"mic: not measured in the latest recording ({stamp}) — re-record to confirm"
            )
        elif is_silent_stream(mic):
            typer.echo(
                f"mic: SILENT in the latest recording ({stamp}) — check Microphone "
                "permission for Oatmeal in System Settings ▸ Privacy & Security"
            )
        else:
            typer.echo(f"mic: ok in the latest recording ({stamp}) — peak {mic.peak} rms {mic.rms}")

    if fetch_model:
        if cached:
            typer.echo("already cached")
        else:
            try:
                _fetch_model(cfg.model)
            except Exception as e:  # network / HF errors — report, exit non-zero
                typer.echo(f"error: failed to fetch model {cfg.model}: {e}", err=True)
                raise typer.Exit(code=1) from e
            typer.echo(f"fetched {cfg.model}")

    if cfg.diarize:
        typer.echo(f"diarization model: {cfg.diarization_model}")
        d_cached = _model_cached(cfg.diarization_model)
        typer.echo(f"diarization model cached: {'yes' if d_cached else 'no'}")
        if fetch_model and not d_cached:
            try:
                _fetch_model(cfg.diarization_model)
            except Exception as e:  # network / HF errors — report, exit non-zero
                typer.echo(
                    f"error: failed to fetch diarization model {cfg.diarization_model}: {e}",
                    err=True,
                )
                raise typer.Exit(code=1) from e
            typer.echo(f"fetched {cfg.diarization_model}")


config_app = typer.Typer(help="Inspect or update mr configuration.")
app.add_typer(config_app, name="config")


@config_app.command("set")
def config_set(
    key: Annotated[str, typer.Argument(help="Config key (v1.1: out_root)")],
    value: Annotated[str, typer.Argument(help="New value")],
) -> None:
    """Set a config value (v1.1: ``mr config set out_root <dir>``)."""
    _do_config_set(key, value)


@config_app.command("get")
def config_get(
    key: Annotated[str, typer.Argument(help="Config key (v1.1: out_root)")],
) -> None:
    """Print the current value of a config key (v1.1: out_root)."""
    _do_config_get(key)


def main() -> None:
    # MUST come before `app()`: multiprocessing re-spawns `sys.executable` with
    # interpreter flags (`-B`, `-c ...`), and in a FROZEN build sys.executable
    # IS the mr-cli binary — so typer parsed `-B` as an unknown option and the
    # pool worker died ("No such option: -B" in .transcribe.log, followed by a
    # resource_tracker leak warning). freeze_support() intercepts those
    # re-spawns before any argument parsing. Same frozen/venv spawn hazard as
    # `_spawn_transcription`; see docs/architecture.md "Pipeline step 2".
    # It is a no-op in a normal venv run and when not a re-spawned child.
    multiprocessing.freeze_support()
    app()


if __name__ == "__main__":
    main()
