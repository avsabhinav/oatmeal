"""Tests for StreamMeta peak/rms parsing and is_silent_stream (MIC-TCC.T5)."""

from mr.core.output import render_transcript_md
from mr.core.schema import (
    CaptureMeta,
    Segment,
    StreamMeta,
    _parse_stream,
    is_silent_stream,
)


def _base_stream_dict() -> dict:
    return {
        "device_name": "MacBook Pro Microphone",
        "native_sample_rate": 48000,
        "native_channels": 1,
        "first_sample_seconds": 0.0,
        "samples_written": 100,
    }


def test_parse_stream_with_peak_rms() -> None:
    mic = dict(_base_stream_dict())
    mic.update({"peak": 0, "rms": 0.0})
    stream = _parse_stream(mic, "mic")
    assert stream.peak == 0
    assert stream.rms == 0.0

    system = dict(_base_stream_dict())
    system.update({"device_name": "MacBook Pro Speakers", "native_channels": 2})
    system.update({"peak": 25884, "rms": 0.0604})
    stream = _parse_stream(system, "system")
    assert stream.peak == 25884
    assert stream.rms == 0.0604


def test_parse_stream_without_peak_rms_legacy() -> None:
    # Backward compatibility: older meta.json files have no peak/rms keys.
    stream = _parse_stream(_base_stream_dict(), "mic")
    assert stream.peak is None
    assert stream.rms is None


def test_parse_stream_with_null_peak_rms() -> None:
    d = dict(_base_stream_dict())
    d.update({"peak": None, "rms": None})
    stream = _parse_stream(d, "mic")
    assert stream.peak is None
    assert stream.rms is None


def test_is_silent_stream_true_when_zero_peak_and_samples() -> None:
    stream = StreamMeta(
        device_name="d",
        native_sample_rate=48000,
        native_channels=1,
        first_sample_seconds=0.0,
        samples_written=100,
        peak=0,
    )
    assert is_silent_stream(stream) is True


def test_is_silent_stream_false_when_no_samples() -> None:
    stream = StreamMeta(
        device_name="d",
        native_sample_rate=48000,
        native_channels=1,
        first_sample_seconds=0.0,
        samples_written=0,
        peak=0,
    )
    assert is_silent_stream(stream) is False


def test_is_silent_stream_false_when_nonzero_peak() -> None:
    stream = StreamMeta(
        device_name="d",
        native_sample_rate=48000,
        native_channels=1,
        first_sample_seconds=0.0,
        samples_written=100,
        peak=42,
    )
    assert is_silent_stream(stream) is False


def _capture(mic: StreamMeta, system: StreamMeta) -> CaptureMeta:
    return CaptureMeta(
        macos_version="27.0.1",
        aec=False,
        started_at="2026-01-15T14:30:00+00:00",
        duration_seconds=10.0,
        mic=mic,
        system=system,
    )


def test_render_transcript_md_warns_on_silent_mic() -> None:
    mic = StreamMeta(
        device_name="m",
        native_sample_rate=48000,
        native_channels=1,
        first_sample_seconds=0.0,
        samples_written=100,
        peak=0,
        rms=0.0,
    )
    system = StreamMeta(
        device_name="s",
        native_sample_rate=48000,
        native_channels=2,
        first_sample_seconds=0.0,
        samples_written=100,
        peak=25884,
        rms=0.06,
    )
    md = render_transcript_md(
        stamp="2026-01-15_1430",
        source_dir="recordings/x",
        segments=[Segment(speaker="Them", text="hi", start=0.0, end=1.0)],
        duration_seconds=10.0,
        capture=_capture(mic, system),
    )
    assert "the microphone track is silent" in md
    assert "system audio" not in md


def test_render_transcript_md_warns_on_silent_system() -> None:
    mic = StreamMeta(
        device_name="m",
        native_sample_rate=48000,
        native_channels=1,
        first_sample_seconds=0.0,
        samples_written=100,
        peak=100,
        rms=0.02,
    )
    system = StreamMeta(
        device_name="s",
        native_sample_rate=48000,
        native_channels=2,
        first_sample_seconds=0.0,
        samples_written=100,
        peak=0,
        rms=0.0,
    )
    md = render_transcript_md(
        stamp="2026-01-15_1430",
        source_dir="recordings/x",
        segments=[Segment(speaker="You", text="hi", start=0.0, end=1.0)],
        duration_seconds=10.0,
        capture=_capture(mic, system),
    )
    assert "system audio track is silent" in md
    assert "microphone track is silent" not in md


def test_render_transcript_md_no_warning_for_legacy_capture() -> None:
    mic = StreamMeta(
        device_name="m",
        native_sample_rate=48000,
        native_channels=1,
        first_sample_seconds=0.0,
        samples_written=100,
    )
    md = render_transcript_md(
        stamp="2026-01-15_1430",
        source_dir="recordings/x",
        segments=[Segment(speaker="You", text="hi", start=0.0, end=1.0)],
        duration_seconds=10.0,
        capture=_capture(mic, mic),
    )
    assert "Warning" not in md


def test_render_transcript_md_no_warning_without_capture() -> None:
    md = render_transcript_md(
        stamp="2026-01-15_1430",
        source_dir="recordings/x",
        segments=[Segment(speaker="You", text="hi", start=0.0, end=1.0)],
        duration_seconds=10.0,
    )
    assert "Warning" not in md
