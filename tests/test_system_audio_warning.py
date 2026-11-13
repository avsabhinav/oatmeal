"""Test that the silent system-audio warning names System Audio Recording (REL-012/3)."""

from mr.core.output import render_transcript_md
from mr.core.schema import CaptureMeta, Segment, StreamMeta


def _capture(mic: StreamMeta, system: StreamMeta) -> CaptureMeta:
    return CaptureMeta(
        macos_version="27.0.1",
        aec=False,
        started_at="2026-01-15T14:30:00+00:00",
        duration_seconds=10.0,
        mic=mic,
        system=system,
    )


def _stream(peak: int) -> StreamMeta:
    return StreamMeta(
        device_name="d",
        native_sample_rate=48000,
        native_channels=1,
        first_sample_seconds=0.0,
        samples_written=100,
        peak=peak,
        rms=0.0 if peak == 0 else 0.02,
    )


def test_silent_system_warning_names_system_audio_recording() -> None:
    mic = _stream(peak=100)  # non-silent mic
    system = _stream(peak=0)  # silent system track
    md = render_transcript_md(
        stamp="2026-01-15_1430",
        source_dir="recordings/x",
        segments=[Segment(speaker="You", text="hi", start=0.0, end=1.0)],
        duration_seconds=10.0,
        capture=_capture(mic, system),
    )
    assert "system audio track is silent" in md
    assert "System Audio Recording permission" in md
    # The system-only warning must not point at the Microphone permission.
    warning = next(
        line
        for line in md.splitlines()
        if line.startswith("- **Warning:**") and "system audio" in line
    )
    assert "Microphone" not in warning
    # REL-012/3 fix 1: System Audio Recording is the mr-capture helper's own
    # permission, not Oatmeal's — the warning must not claim Oatmeal attribution.
    assert "mr-capture" in warning
    assert "for Oatmeal" not in warning
    # Non-silent mic produces no microphone warning at all.
    assert "microphone track is silent" not in md


def test_silent_mic_warning_still_names_microphone() -> None:
    mic = _stream(peak=0)  # silent mic
    system = _stream(peak=100)  # non-silent system
    md = render_transcript_md(
        stamp="2026-01-15_1430",
        source_dir="recordings/x",
        segments=[Segment(speaker="You", text="hi", start=0.0, end=1.0)],
        duration_seconds=10.0,
        capture=_capture(mic, system),
    )
    assert "microphone track is silent" in md
    assert "Microphone permission" in md
    assert "System Audio Recording" not in md
