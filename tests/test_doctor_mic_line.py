"""Tests for `_latest_recording_meta`, the fail-soft helper behind `mr doctor`'s mic line."""

from __future__ import annotations

import json

from mr.cli import _latest_recording_meta
from mr.core.schema import is_silent_stream

BASE = {
    "aec": False,
    "macos_version": "v",
    "started_at": "t",
    "duration_seconds": 1.0,
    "mic": {
        "device_name": "m",
        "native_sample_rate": 48000,
        "native_channels": 1,
        "first_sample_seconds": 0.0,
        "samples_written": 100,
        "peak": 0,
        "rms": 0.0,
    },
    "system": {
        "device_name": "s",
        "native_sample_rate": 48000,
        "native_channels": 2,
        "first_sample_seconds": 0.0,
        "samples_written": 100,
        "peak": 5,
        "rms": 0.01,
    },
}


def _write_meta(root, stamp: str, meta: dict) -> None:
    d = root / "recordings" / stamp
    d.mkdir(parents=True)
    (d / "meta.json").write_text(json.dumps(meta), encoding="utf-8")


def test_silent_mic(tmp_path):
    _write_meta(tmp_path, "2026-11-10_1130", BASE)
    result = _latest_recording_meta(str(tmp_path))
    assert result is not None
    stamp, capture = result
    assert stamp == "2026-11-10_1130"
    assert is_silent_stream(capture.mic) is True


def test_healthy_mic(tmp_path):
    meta = json.loads(json.dumps(BASE))
    meta["mic"]["peak"] = 25884
    meta["mic"]["rms"] = 0.0604
    _write_meta(tmp_path, "2026-11-10_1130", meta)
    result = _latest_recording_meta(str(tmp_path))
    assert result is not None
    stamp, capture = result
    assert stamp == "2026-11-10_1130"
    assert capture.mic.peak == 25884
    assert is_silent_stream(capture.mic) is False


def test_legacy_meta_without_level_fields(tmp_path):
    meta = json.loads(json.dumps(BASE))
    del meta["mic"]["peak"]
    del meta["mic"]["rms"]
    del meta["system"]["peak"]
    del meta["system"]["rms"]
    _write_meta(tmp_path, "2026-11-10_0959", meta)
    result = _latest_recording_meta(str(tmp_path))
    assert result is not None
    stamp, capture = result
    assert stamp == "2026-11-10_0959"
    assert capture.mic.peak is None


def test_recordings_dir_absent(tmp_path):
    assert _latest_recording_meta(str(tmp_path)) is None


def test_recordings_dir_empty(tmp_path):
    (tmp_path / "recordings").mkdir()
    assert _latest_recording_meta(str(tmp_path)) is None


def test_picks_lexicographically_greatest_stamp(tmp_path):
    _write_meta(tmp_path, "2026-11-10_0959", BASE)
    healthy = json.loads(json.dumps(BASE))
    healthy["mic"]["peak"] = 25884
    _write_meta(tmp_path, "2026-11-10_1130", healthy)
    result = _latest_recording_meta(str(tmp_path))
    assert result is not None
    stamp, capture = result
    assert stamp == "2026-11-10_1130"
    assert capture.mic.peak == 25884
