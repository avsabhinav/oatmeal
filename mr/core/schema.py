"""Shared data-model dataclasses for the `mr` core.

Frozen, json-serializable (via ``dataclasses.asdict``) dataclasses that every
other core module imports: transcribe, merge, output, capture.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Word:
    """A single word-level timestamp as produced by Whisper."""

    text: str
    start: float
    end: float
    probability: float


@dataclass(frozen=True)
class Segment:
    """A contiguous attributed utterance.

    ``echo_suspected`` marks a ``You`` segment that the merge step believes is
    residual acoustic echo of concurrent ``Them`` audio. Such segments are
    omitted from the Markdown transcript but kept in the JSON sidecar: the
    dedup heuristic is fallible, and a faithful transcript must never delete
    speech unrecoverably. Defaulted so ``dataclasses.asdict`` and every
    existing positional construction keep working.
    """

    speaker: str  # "You" (mic); "Them" or "Speaker N" (system, when diarized)
    text: str
    start: float
    end: float
    words: tuple[Word, ...] = ()
    echo_suspected: bool = False


@dataclass(frozen=True)
class TranscriptionResult:
    """The result of transcribing one audio track."""

    track: str  # "mic" or "system"
    speaker: str  # "You" for mic, "Them" for system
    model: str
    audio_seconds: float
    wall_seconds: float
    settings: dict[str, object]
    segments: tuple[Segment, ...] = ()


@dataclass(frozen=True)
class StreamMeta:
    """Per-stream capture metadata (mic or system).

    ``peak`` (peak absolute 16-bit sample value; ``0`` means every sample was
    zero) and ``rms`` (0..1) describe how loud the captured stream was. Both
    default to ``None`` so recordings made before the capture helper wrote
    these fields still parse.
    """

    device_name: str
    native_sample_rate: int
    native_channels: int
    first_sample_seconds: float
    samples_written: int
    peak: int | None = None
    rms: float | None = None


def is_silent_stream(stream: StreamMeta) -> bool:
    """True when the stream delivered samples but every sample was zero.

    A stream that was never started (``samples_written == 0``) is not silent —
    there is simply nothing to judge, and absence of data is not evidence of
    silence.
    """
    return stream.peak == 0 and stream.samples_written > 0


@dataclass(frozen=True)
class CaptureMeta:
    """Capture metadata parsed from `mr-capture`'s ``meta.json``."""

    macos_version: str
    aec: bool
    started_at: str  # ISO8601
    duration_seconds: float
    mic: StreamMeta
    system: StreamMeta


def _parse_stream(d: dict, key: str) -> StreamMeta:
    if not isinstance(d, dict):
        raise ValueError(f"capture meta: {key!r} must be a dict, got {type(d).__name__}")
    return StreamMeta(
        device_name=str(d["device_name"]),
        native_sample_rate=int(d["native_sample_rate"]),
        native_channels=int(d["native_channels"]),
        first_sample_seconds=float(d["first_sample_seconds"]),
        samples_written=int(d["samples_written"]),
        peak=int(d["peak"]) if "peak" in d and d["peak"] is not None else None,
        rms=float(d["rms"]) if "rms" in d and d["rms"] is not None else None,
    )


def from_capture_dict(d: dict) -> CaptureMeta:
    """Parse the ``meta.json`` produced by ``mr-capture`` into a :class:`CaptureMeta`.

    Raises ``ValueError`` if the top-level ``"mic"`` or ``"system"`` stream key
    is missing or not a dict.
    """
    if "mic" not in d or "system" not in d:
        missing = [k for k in ("mic", "system") if k not in d]
        raise ValueError(f"capture meta is missing stream key(s): {', '.join(missing)!r}")
    return CaptureMeta(
        macos_version=str(d["macos_version"]),
        aec=bool(d["aec"]),
        started_at=str(d["started_at"]),
        duration_seconds=float(d["duration_seconds"]),
        mic=_parse_stream(d["mic"], "mic"),
        system=_parse_stream(d["system"], "system"),
    )


def format_ts(seconds: float) -> str:
    """Format seconds as ``MM:SS`` with zero-padded, floored components.

    Examples: ``format_ts(0) == "00:00"``, ``format_ts(67.9) == "01:07"``,
    ``format_ts(3660.5) == "61:00"``. Minutes may exceed 99.
    """
    total = int(seconds)  # floor for non-negative input
    return f"{total // 60:02d}:{total % 60:02d}"
