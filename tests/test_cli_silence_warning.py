"""Fail-soft tests for ``mr.cli._read_capture_meta``.

These pin the exact contract the silent-track warning relies on: a valid
``meta.json`` parses into a :class:`~mr.core.schema.CaptureMeta`, while a
missing, malformed, or legacy ``meta.json`` yields ``None`` (or parses with
``peak``/``rms`` left as ``None``) without ever raising.
"""

from __future__ import annotations

import json
from pathlib import Path

from mr.cli import _read_capture_meta
from mr.core.schema import CaptureMeta


def _meta_dict() -> dict[str, object]:
    """A realistic ``meta.json`` body with a silent (peak 0) mic stream."""
    return {
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


def test_reads_silent_mic_meta(tmp_path: Path) -> None:
    (tmp_path / "meta.json").write_text(json.dumps(_meta_dict()), encoding="utf-8")
    meta = _read_capture_meta(tmp_path)
    assert isinstance(meta, CaptureMeta)
    assert meta.mic.peak == 0
    assert meta.mic.samples_written == 100


def test_returns_none_when_meta_missing(tmp_path: Path) -> None:
    assert _read_capture_meta(tmp_path) is None


def test_returns_none_for_invalid_json(tmp_path: Path) -> None:
    (tmp_path / "meta.json").write_text("not json", encoding="utf-8")
    assert _read_capture_meta(tmp_path) is None


def test_legacy_meta_without_peak_or_rms(tmp_path: Path) -> None:
    # Older builds wrote the mic stream without the ``peak``/``rms`` keys at all.
    body = _meta_dict()
    del body["mic"]["peak"]  # type: ignore[typeddict-item]
    del body["mic"]["rms"]  # type: ignore[typeddict-item]
    (tmp_path / "meta.json").write_text(json.dumps(body), encoding="utf-8")

    meta = _read_capture_meta(tmp_path)
    assert isinstance(meta, CaptureMeta)
    assert meta.mic.peak is None
    assert meta.mic.rms is None
