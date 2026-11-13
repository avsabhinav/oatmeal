"""Transcript writers: Markdown (`.md`) and optional JSON sidecar.

Pure rendering functions plus thin path-writing helpers. All rendering is
deterministic string/dict construction — no I/O beyond ``write_transcript``
and ``write_json``.
"""

from __future__ import annotations

import json
from datetime import date
from pathlib import Path

from mr.core.schema import CaptureMeta, Segment, format_ts, is_silent_stream

#: v2: system-side ``speaker`` may be ``Speaker N`` (diarized); every segment
#: carries ``track`` (``mic``/``system``) so consumers need not parse labels.
SCHEMA_VERSION = 2
PARTICIPANTS_LINE = "You (mic), Them (system)"


def _track(speaker: str) -> str:
    return "mic" if speaker == "You" else "system"


def _label_key(label: str) -> tuple[int, str]:
    """Order ``Speaker 2`` before ``Speaker 10``; non-numbered labels last."""
    head, _, num = label.rpartition(" ")
    return (int(num), head) if num.isdigit() else (1 << 30, label)


def participants_line(segments: list[Segment]) -> str:
    """``You (mic), Speaker 1, Speaker 2 (system)``; the fixed line when undiarized."""
    system = sorted({s.speaker for s in segments if s.speaker != "You"}, key=_label_key)
    if not system or system == ["Them"]:
        return PARTICIPANTS_LINE
    return f"You (mic), {', '.join(system)} (system)"

#: Suffix appended to a segment the merge step suspects is echo of the other
#: side's audio. Reaching the Markdown at all is now the exception: the merge
#: removes echo word by word, so a flagged segment is one that had no word
#: timings to trim (``Segment.words`` empty) and could only be judged whole.
#: Marked rather than hidden, because hiding it would delete whatever genuine
#: speech shares the segment.
ECHO_MARKER = "*(possible echo)*"

# First characters that give a bare YAML scalar special meaning.
_YAML_SPECIAL_FIRST = set("-?:[]{}#&*!|>'\"%@\u0060")


def _format_duration(seconds: float) -> str:
    """Format total seconds as ``<m>m <s>s`` with floored components."""
    total = int(seconds)  # floor for non-negative input
    return f"{total // 60}m {total % 60}s"


def _yaml_scalar(value: str) -> str:
    """Emit ``value`` as an Obsidian-safe YAML scalar.

    Quoted (double, with ``"`` escaped) when the value contains ``": "``
    or starts with a YAML-meaningful character; bare otherwise.
    """
    if ": " in value or (value and value[0] in _YAML_SPECIAL_FIRST):
        return '"' + value.replace('"', '\\"') + '"'
    return value


def _attendees_flow(attendees: list[object]) -> str:
    """Render an attendees list as a YAML flow list, quoting as needed."""
    parts = []
    for a in attendees:
        s = str(a)
        if "," in s or ": " in s:
            s = '"' + s.replace('"', '\\"') + '"'
        parts.append(s)
    return "[" + ", ".join(parts) + "]"


def _render_frontmatter(
    *,
    context: dict[str, object],
    stamp: str,
    source_dir: str,
    duration_seconds: float,
) -> str:
    """Build the ``---``-delimited Obsidian YAML frontmatter block."""
    title = str(context.get("title") or stamp)
    start = context.get("start")
    date_value = str(start) if start else date.today().isoformat()
    lines = [
        "---",
        f"title: {_yaml_scalar(title)}",
        f"date: {_yaml_scalar(date_value)}",
    ]
    attendees = context.get("attendees")
    if isinstance(attendees, list) and attendees:
        lines.append(f"attendees: {_attendees_flow(attendees)}")
    notes = context.get("notes")
    if isinstance(notes, str) and notes:
        lines.append(f"notes: {_yaml_scalar(notes)}")
    lines.append(f"duration: {_format_duration(duration_seconds)}")
    lines.append(f"source: {_yaml_scalar(source_dir)}")
    lines.append("---")
    return "\n".join(lines)


def _silence_warnings(capture: CaptureMeta | None) -> list[str]:
    """Header warning lines for silent tracks; empty when none qualify.

    Only streams that actually delivered samples (``samples_written > 0``)
    with a zero peak are reported: absence of ``peak`` data (older recordings)
    is not evidence of silence.
    """
    if capture is None:
        return []
    lines: list[str] = []
    if is_silent_stream(capture.mic):
        lines.append(
            "- **Warning:** the microphone track is silent (all samples zero). "
            "`You` lines are missing because no audio was captured. Check "
            "Microphone permission for Oatmeal in System Settings ▸ "
            "Privacy & Security."
        )
    if is_silent_stream(capture.system):
        lines.append(
            "- **Warning:** the system audio track is silent (all samples zero). "
            "No system speech was captured. Check System Audio Recording permission "
            "for the mr-capture helper (system audio capture) in System Settings ▸ "
            "Privacy & Security."
        )
    return lines


def render_transcript_md(
    *,
    stamp: str,
    source_dir: str,
    segments: list[Segment],
    duration_seconds: float,
    context: dict[str, object] | None = None,
    capture: CaptureMeta | None = None,
) -> str:
    """Render the transcript Markdown as a pure string (no file I/O).

    Segments marked ``echo_suspected`` are printed with a
    :data:`ECHO_MARKER` suffix rather than omitted. The merge now strips
    echo word by word, so a segment arrives here flagged only when it had no
    word timings to trim and had to be judged whole. Hiding such a segment
    would delete whatever genuine speech shares it; marking it cannot, and
    the reader can judge the duplicate for themselves.

    When ``context`` is a non-empty dict, an Obsidian YAML frontmatter
    block is prepended; otherwise the output is unchanged.

    When ``capture`` is given and a track was silent (samples delivered,
    all zero), a warning line is added to the header so a denied
    microphone is visible at the top of the transcript.
    """
    lines = [
        f"# Meeting — {stamp}",
        "",
        f"- **Duration:** {_format_duration(duration_seconds)}",
        f"- **Participants:** {participants_line(segments)}",
        f"- **Source:** {source_dir}",
        *_silence_warnings(capture),
        "",
        "## Transcript",
        "",
    ]
    for seg in segments:
        suffix = f" {ECHO_MARKER}" if seg.echo_suspected else ""
        lines.append(f"**{seg.speaker} ({format_ts(seg.start)}):** {seg.text}{suffix}")
        lines.append("")
    # Join and drop the trailing blank line added after the last segment.
    body = "\n".join(lines).rstrip("\n")
    if not context:
        return body
    return _render_frontmatter(
        context=context, stamp=stamp, source_dir=source_dir, duration_seconds=duration_seconds
    ) + "\n\n" + body


def write_transcript(md_path: str | Path, text: str) -> None:
    """Write transcript text to ``md_path``, creating parent dirs.

    Ensures the file ends with exactly one trailing newline.
    """
    path = Path(md_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    if not text.endswith("\n"):
        text += "\n"
    path.write_text(text, encoding="utf-8")


def render_transcript_json(
    segments: list[Segment], *, stamp: str, context: dict[str, object] | None = None
) -> dict:
    """Build the JSON sidecar payload as plain dict/list (no file I/O).

    Every segment is included, echo-suspected ones carrying
    ``"echo_suspected": true``. The Markdown now marks those segments rather
    than hiding them, so the sidecar is no longer the only place they
    survive; it remains the machine-readable record, and the only one
    carrying word-level timings. The key is emitted only when true, keeping
    the payload unchanged for recordings with no suspected echo.

    When ``context`` is a non-empty dict, it is included as a ``"context"``
    key (the raw passed-in dict); otherwise the output is unchanged.
    """
    segment_payloads: list[dict] = []
    for seg in segments:
        entry: dict = {
            "speaker": seg.speaker,
            "track": _track(seg.speaker),
            "start": seg.start,
            "end": seg.end,
            "text": seg.text,
        }
        if seg.echo_suspected:
            entry["echo_suspected"] = True
        segment_payloads.append(entry)
    payload: dict = {
        "schema_version": SCHEMA_VERSION,
        "stamp": stamp,
        "segments": segment_payloads,
    }
    if context:
        payload["context"] = context
    return payload


def write_json(json_path: str | Path, data: dict) -> None:
    """Write ``data`` as pretty-printed JSON to ``json_path``, creating parent dirs."""
    path = Path(json_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
