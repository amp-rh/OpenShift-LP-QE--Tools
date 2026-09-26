#!/usr/bin/env python3
"""Pure reliability primitives for the RHOV BSOD detector.

This module deliberately has no cluster client.  Runtime shell scripts feed it
captured command output; fixture tests feed it the same formats.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from pathlib import Path


def emit(value: dict, exit_code: int = 0) -> None:
    print(json.dumps(value, sort_keys=True))
    raise SystemExit(exit_code)


def crash_decision(args: argparse.Namespace) -> None:
    state = args.domstate.strip().lower() or "unavailable"
    phase = args.vmi_phase.strip().lower() or "unavailable"
    if args.misses < args.threshold:
        emit({"decision": "observe", "reason": "threshold-not-reached"})
    if args.pvpanic:
        emit({"decision": "capture", "reason": "current-pvpanic-event"})
    if phase not in {"running", "scheduled"}:
        emit({"decision": "fail", "reason": f"vmi-phase-{phase}"}, 1)
    if not args.pod_present:
        emit({"decision": "fail", "reason": "launcher-unavailable"}, 1)
    if state in {"crashed", "paused", "pmsuspended"}:
        emit({"decision": "capture", "reason": f"qga-threshold-domstate-{state}"})
    emit({"decision": "fail", "reason": f"ambiguous-domstate-{state}"}, 1)


def parse_domstats(text: str, device: str) -> int:
    names: dict[str, str] = {}
    writes: dict[str, int] = {}
    for raw in text.splitlines():
        line = raw.strip()
        match = re.fullmatch(r"block\.(\d+)\.name=(.+)", line)
        if match:
            names[match.group(1)] = match.group(2).strip()
            continue
        match = re.fullmatch(r"block\.(\d+)\.wr\.bytes=(\d+)", line)
        if match:
            writes[match.group(1)] = int(match.group(2))
    indexes = [index for index, name in names.items() if name == device]
    if len(indexes) != 1 or indexes[0] not in writes:
        raise ValueError(f"statistics unavailable for disk target {device}")
    return writes[indexes[0]]


def domstats(args: argparse.Namespace) -> None:
    try:
        value = parse_domstats(sys.stdin.read(), args.device)
    except ValueError as exc:
        emit({"status": "unavailable", "reason": str(exc)}, 1)
    emit({"status": "ok", "device": args.device, "writeBytes": value})


def initial_progress_state(device: str) -> dict:
    return {"device": device, "last": None, "observedProgress": False, "idleSamples": 0, "samples": 0}


def advance_progress(state: dict, current: int, idle_samples: int) -> dict:
    last = state["last"]
    state["samples"] += 1
    if last is None:
        status, reason = "waiting", "baseline-recorded"
    elif current < last:
        status, reason = "failure", "write-counter-regressed"
    elif current > last:
        state["observedProgress"] = True
        state["idleSamples"] = 0
        status, reason = "waiting", "write-progress"
    elif state["observedProgress"]:
        state["idleSamples"] += 1
        if state["idleSamples"] >= idle_samples:
            status, reason = "complete", "progress-then-quiescence"
        else:
            status, reason = "waiting", "quiescing"
    else:
        status, reason = "waiting", "no-progress-observed"
    state["last"] = current
    return {"status": status, "reason": reason, "writeBytes": current, **state}


def progress_step(args: argparse.Namespace) -> None:
    state_path = Path(args.state)
    state = json.loads(state_path.read_text(encoding="utf-8")) if state_path.exists() else initial_progress_state(args.device)
    if state.get("device") != args.device:
        emit({"status": "failure", "reason": "disk-target-changed"}, 1)
    try:
        current = parse_domstats(sys.stdin.read(), args.device)
    except ValueError as exc:
        emit({"status": "failure", "reason": "statistics-unavailable", "detail": str(exc)}, 1)
    result = advance_progress(state, current, args.idle_samples)
    state_path.write_text(json.dumps(state, sort_keys=True), encoding="utf-8")
    emit(result, 1 if result["status"] == "failure" else 0)


def progress_sequence(args: argparse.Namespace) -> None:
    try:
        samples = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        emit({"status": "failure", "reason": "invalid-sequence", "detail": str(exc)}, 1)
    state = initial_progress_state(args.device)
    result = {"status": "failure", "reason": "empty-sequence"}
    for text in samples:
        try:
            current = parse_domstats(text, args.device)
        except ValueError as exc:
            emit({"status": "failure", "reason": "statistics-unavailable", "detail": str(exc)}, 1)
        result = advance_progress(state, current, args.idle_samples)
        if result["status"] in {"complete", "failure"}:
            emit(result, 1 if result["status"] == "failure" else 0)
    reason = "quiescence-timeout" if state["observedProgress"] else "no-progress-timeout"
    emit({"status": "failure", "reason": reason, **state}, 1)


def artifact_type(path: Path, requested: str) -> tuple[bool, str]:
    with path.open("rb") as stream:
        data = stream.read(16)
    if requested == "screenshot":
        if data.startswith(b"\x89PNG\r\n\x1a\n"):
            return True, "png"
        if data.startswith((b"P6\n", b"P3\n", b"P6 ", b"P3 ")):
            return True, "ppm"
        return False, "unknown"
    if requested == "memory":
        return data.startswith(b"\x7fELF"), "elf"
    if requested == "dump":
        if data.startswith(b"PAGEDU64"):
            return True, "windows-pagedu64"
        if data.startswith(b"MDMP"):
            return True, "windows-minidump"
        return False, "unknown"
    if requested == "evtx":
        return data.startswith(b"ElfFile\x00"), "evtx"
    if requested == "json":
        try:
            json.loads(path.read_text(encoding="utf-8"))
            return True, "json"
        except (json.JSONDecodeError, UnicodeDecodeError):
            return False, "invalid-json"
    return bool(data), "text"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def validate_artifact(args: argparse.Namespace) -> None:
    path = Path(args.path)
    if not path.is_file() or path.stat().st_size <= 0:
        emit({"ok": False, "path": str(path), "error": "missing-or-empty"}, 1)
    valid, detected = artifact_type(path, args.type)
    if not valid:
        emit({"ok": False, "path": str(path), "error": "invalid-signature", "format": detected}, 1)
    digest = sha256_file(path)
    emit({
        "ok": True,
        "path": str(path),
        "size": path.stat().st_size,
        "format": detected,
        "sha256": digest,
    })


def classify(path: Path) -> str | None:
    name = path.name.lower()
    if name == "checksums.sha256":
        return "checksums"
    if name.endswith((".png", ".ppm")) and "screenshot" in name:
        return "screenshot"
    if name.endswith(".elf") and "memory" in name:
        return "memory"
    if name.endswith(".dmp"):
        return "dump"
    if name.endswith(".evtx"):
        return "evtx"
    if name.endswith(".json"):
        return "json"
    if name.endswith((".log", ".xml")):
        return "log"
    return None


def write_summary(args: argparse.Namespace) -> None:
    out = Path(args.out).resolve()
    stage_errors: list[dict] = []
    stage_file = Path(args.stage_errors)
    if stage_file.exists():
        for number, line in enumerate(stage_file.read_text(encoding="utf-8").splitlines(), 1):
            if not line.strip():
                continue
            try:
                stage_errors.append(json.loads(line))
            except json.JSONDecodeError:
                stage_errors.append({"stage": "summary", "error": f"invalid stage error line {number}"})

    artifacts: list[dict] = []
    invalid: list[dict] = []
    found = {"screenshot": 0, "memory": 0, "dump": 0, "evtx": 0, "log": 0}
    excluded = {"evidence-summary.json", "recovery-summary.json"}
    for path in sorted(out.rglob("*")):
        if not path.is_file() or path.name in excluded or path == stage_file:
            continue
        kind = classify(path)
        if kind is None:
            continue
        valid, detected = artifact_type(path, kind)
        record = {
            "path": str(path.relative_to(out)),
            "type": kind,
            "format": detected,
            "size": path.stat().st_size,
            "sha256": sha256_file(path),
            "valid": valid,
        }
        artifacts.append(record)
        if valid and kind in found:
            found[kind] += 1
        if not valid:
            invalid.append(record)
    missing = [kind for kind, count in found.items() if count == 0]
    ok = not stage_errors and not invalid and not missing
    summary = {
        "ok": ok,
        "mode": args.mode,
        "vm": args.vm,
        "namespace": args.namespace,
        "artifacts": artifacts,
        "stageErrors": stage_errors,
        "invalidArtifacts": invalid,
        "missingRequiredArtifactTypes": missing,
    }
    target = out / args.filename
    temporary = target.with_suffix(target.suffix + ".tmp")
    temporary.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, target)
    print(json.dumps(summary, sort_keys=True))
    raise SystemExit(0 if ok else 1)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    commands = result.add_subparsers(dest="command", required=True)

    decision = commands.add_parser("decision")
    decision.add_argument("--misses", type=int, required=True)
    decision.add_argument("--threshold", type=int, required=True)
    decision.add_argument("--domstate", required=True)
    decision.add_argument("--vmi-phase", required=True)
    decision.add_argument("--pvpanic", action="store_true")
    decision.add_argument("--pod-present", action="store_true")
    decision.set_defaults(func=crash_decision)

    stats = commands.add_parser("domstats")
    stats.add_argument("--device", required=True)
    stats.set_defaults(func=domstats)

    progress = commands.add_parser("progress-step")
    progress.add_argument("--device", required=True)
    progress.add_argument("--state", required=True)
    progress.add_argument("--idle-samples", type=int, default=3)
    progress.set_defaults(func=progress_step)

    sequence = commands.add_parser("progress-sequence")
    sequence.add_argument("--device", required=True)
    sequence.add_argument("--idle-samples", type=int, default=3)
    sequence.set_defaults(func=progress_sequence)

    artifact = commands.add_parser("validate-artifact")
    artifact.add_argument("--type", choices=["screenshot", "memory", "dump", "evtx", "json", "log"], required=True)
    artifact.add_argument("--path", required=True)
    artifact.set_defaults(func=validate_artifact)

    summary = commands.add_parser("write-summary")
    summary.add_argument("--out", required=True)
    summary.add_argument("--stage-errors", required=True)
    summary.add_argument("--mode", required=True)
    summary.add_argument("--vm", required=True)
    summary.add_argument("--namespace", required=True)
    summary.add_argument("--filename", default="evidence-summary.json")
    summary.set_defaults(func=write_summary)
    return result


if __name__ == "__main__":
    parsed = parser().parse_args()
    parsed.func(parsed)
