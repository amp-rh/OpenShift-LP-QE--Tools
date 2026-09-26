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
import struct
import sys
import xml.etree.ElementTree as ET
import zlib
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


def _validate_png(path: Path) -> bool:
    data = path.read_bytes()
    if len(data) < 45 or not data.startswith(b"\x89PNG\r\n\x1a\n"):
        return False
    offset = 8
    seen_ihdr = False
    while offset + 12 <= len(data):
        length = struct.unpack_from(">I", data, offset)[0]
        end = offset + 12 + length
        if end > len(data):
            return False
        chunk_type = data[offset + 4:offset + 8]
        payload = data[offset + 8:offset + 8 + length]
        expected_crc = struct.unpack_from(">I", data, offset + 8 + length)[0]
        if zlib.crc32(chunk_type + payload) & 0xFFFFFFFF != expected_crc:
            return False
        if not seen_ihdr:
            if chunk_type != b"IHDR" or length != 13:
                return False
            width, height = struct.unpack_from(">II", payload)[0:2]
            if width == 0 or height == 0:
                return False
            seen_ihdr = True
        if chunk_type == b"IEND":
            return length == 0 and end == len(data)
        offset = end
    return False


def _validate_ppm(data: bytes) -> bool:
    match = re.match(rb"P([36])\s+(\d+)\s+(\d+)\s+(\d+)\s", data[:256])
    if not match:
        return False
    width, height, maximum = (int(value) for value in match.groups()[1:])
    return width > 0 and height > 0 and 0 < maximum <= 65535 and len(data) > match.end()


def _validate_elf(path: Path, data: bytes) -> bool:
    if len(data) < 64 or data[:4] != b"\x7fELF" or data[6] != 1:
        return False
    elf_class, endian = data[4], data[5]
    if elf_class not in {1, 2} or endian not in {1, 2}:
        return False
    order = "<" if endian == 1 else ">"
    header_size = struct.unpack_from(order + "H", data, 0x34 if elf_class == 2 else 0x28)[0]
    if header_size != (64 if elf_class == 2 else 52) or struct.unpack_from(order + "H", data, 0x10)[0] != 4:
        return False
    if elf_class == 2:
        program_offset = struct.unpack_from(order + "Q", data, 0x20)[0]
        entry_size, count = struct.unpack_from(order + "HH", data, 0x36)
    else:
        program_offset = struct.unpack_from(order + "I", data, 0x1C)[0]
        entry_size, count = struct.unpack_from(order + "HH", data, 0x2A)
    if count == 0 or entry_size < (56 if elf_class == 2 else 32) or count > 65535:
        return False
    table_size = entry_size * count
    if program_offset < header_size or program_offset + table_size > path.stat().st_size or table_size > 16 * 1024 * 1024:
        return False
    with path.open("rb") as stream:
        stream.seek(program_offset)
        table = stream.read(table_size)
    maximum = program_offset + table_size
    for index in range(count):
        entry = table[index * entry_size:(index + 1) * entry_size]
        if elf_class == 2:
            file_offset = struct.unpack_from(order + "Q", entry, 8)[0]
            file_size = struct.unpack_from(order + "Q", entry, 32)[0]
        else:
            file_offset = struct.unpack_from(order + "I", entry, 4)[0]
            file_size = struct.unpack_from(order + "I", entry, 16)[0]
        maximum = max(maximum, file_offset + file_size)
    if maximum > path.stat().st_size:
        return False
    with path.open("rb") as stream:
        stream.seek(maximum)
        trailing = stream.read()
    return not trailing or all(byte == 0 for byte in trailing)


def _validate_dump(path: Path, data: bytes) -> tuple[bool, str]:
    if data.startswith(b"PAGEDU64"):
        return path.stat().st_size >= 0x2000, "windows-pagedu64"
    if data.startswith(b"MDMP"):
        if len(data) < 32:
            return False, "windows-minidump"
        stream_count, directory_rva = struct.unpack_from("<II", data, 8)
        directory_end = directory_rva + stream_count * 12
        if not (stream_count > 0 and 32 <= directory_rva and directory_end <= path.stat().st_size):
            return False, "windows-minidump"
        with path.open("rb") as stream:
            stream.seek(directory_rva)
            directory = stream.read(stream_count * 12)
        maximum = directory_end
        for index in range(stream_count):
            data_size, rva = struct.unpack_from("<II", directory, index * 12 + 4)
            maximum = max(maximum, rva + data_size)
        if maximum > path.stat().st_size:
            return False, "windows-minidump"
        with path.open("rb") as stream:
            stream.seek(maximum)
            trailing = stream.read()
        return (not trailing or all(byte == 0 for byte in trailing)), "windows-minidump"
    return False, "unknown"


def _validate_evtx(data: bytes) -> bool:
    if len(data) < 4096 or not data.startswith(b"ElfFile\x00"):
        return False
    header_size = struct.unpack_from("<I", data, 0x78)[0]
    return header_size == 4096


def artifact_type(path: Path, requested: str) -> tuple[bool, str]:
    with path.open("rb") as stream:
        data = stream.read(4096)
    if requested == "screenshot":
        if data.startswith(b"\x89PNG\r\n\x1a\n"):
            return _validate_png(path), "png"
        if data.startswith((b"P6", b"P3")):
            return _validate_ppm(data), "ppm"
        return False, "unknown"
    if requested == "memory":
        return _validate_elf(path, data), "elf"
    if requested == "dump":
        return _validate_dump(path, data)
    if requested == "evtx":
        return _validate_evtx(data), "evtx"
    if requested == "json":
        try:
            json.loads(path.read_text(encoding="utf-8"))
            return True, "json"
        except (json.JSONDecodeError, UnicodeDecodeError):
            return False, "invalid-json"
    return bool(data) and b"\x00" not in data[:4096], "text"


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


REQUIRED_TYPES = {
    "natural-rhov": {"screenshot", "memory", "dump", "evtx", "log", "json", "checksums"},
    "intentional-rhov": {"screenshot", "memory", "dump", "evtx", "log", "json", "checksums"},
    "rhov-snapshot-recovery": {"dump", "evtx", "log", "json", "checksums"},
    "fixture": {"screenshot", "memory", "dump", "evtx", "log"},
}


SEMANTIC_RESULTS = {"parse-dump-header.json", "events.json"}
REQUIRED_RESULT_FILES = {
    "natural-rhov": SEMANTIC_RESULTS,
    "intentional-rhov": SEMANTIC_RESULTS,
    "rhov-snapshot-recovery": SEMANTIC_RESULTS,
}


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
    required = REQUIRED_TYPES.get(args.mode)
    if required is None:
        stage_errors.append({"stage": "summary", "error": f"unknown summary mode: {args.mode}"})
        required = set()
    found = {kind: 0 for kind in required}
    excluded = {"evidence-summary.json", "recovery-summary.json"}
    for path in sorted(out.rglob("*")):
        if not path.is_file() or path.name in excluded or path == stage_file:
            continue
        kind = classify(path)
        if kind is None:
            continue
        valid, detected = artifact_type(path, kind)
        semantic_error = None
        if valid and path.name in SEMANTIC_RESULTS:
            value = json.loads(path.read_text(encoding="utf-8"))
            if value.get("ok") is not True:
                valid = False
                semantic_error = "stage-result-reports-failure"
        record = {
            "path": str(path.relative_to(out)),
            "type": kind,
            "format": detected,
            "size": path.stat().st_size,
            "sha256": sha256_file(path),
            "valid": valid,
        }
        if semantic_error:
            record["error"] = semantic_error
        artifacts.append(record)
        if valid and kind in found:
            found[kind] += 1
        if not valid:
            invalid.append(record)
    missing = sorted(kind for kind, count in found.items() if count == 0)
    artifact_paths = {item["path"] for item in artifacts}
    for filename in sorted(REQUIRED_RESULT_FILES.get(args.mode, set())):
        if filename not in artifact_paths:
            missing.append(f"json:{filename}")
    ok = not stage_errors and not invalid and not missing
    summary = {
        "ok": ok,
        "mode": args.mode,
        "vm": args.vm,
        "namespace": args.namespace,
        "runId": args.run_id,
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


def map_disk(args: argparse.Namespace) -> None:
    try:
        vmi = json.loads(Path(args.vmi_json).read_text(encoding="utf-8"))
        root = ET.parse(args.domain_xml).getroot()
    except (OSError, json.JSONDecodeError, ET.ParseError) as exc:
        emit({"ok": False, "error": f"invalid mapping input: {exc}"}, 1)

    targets: dict[str, str] = {}
    for disk in root.findall(".//devices/disk"):
        target = disk.find("target")
        alias = disk.find("alias")
        if target is None or alias is None:
            continue
        device = target.get("dev", "")
        alias_name = alias.get("name", "")
        if alias_name.startswith("ua-") and device:
            targets[device] = alias_name[3:]

    volumes = {item.get("name"): item for item in vmi.get("spec", {}).get("volumes", [])}
    candidates = []
    for target, disk_name in targets.items():
        if args.target and target != args.target:
            continue
        volume = volumes.get(disk_name, {})
        claim = (volume.get("persistentVolumeClaim") or {}).get("claimName")
        claim = claim or (volume.get("dataVolume") or {}).get("name")
        if claim:
            candidates.append({"diskTarget": target, "diskName": disk_name, "guestPvc": claim})

    if len(candidates) != 1:
        emit({
            "ok": False,
            "error": "disk target does not map uniquely to a PVC/DataVolume",
            "requestedTarget": args.target or None,
            "candidates": candidates,
        }, 1)
    emit({"ok": True, **candidates[0]})


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
    summary.add_argument("--run-id", default="")
    summary.set_defaults(func=write_summary)

    mapping = commands.add_parser("map-disk")
    mapping.add_argument("--vmi-json", required=True)
    mapping.add_argument("--domain-xml", required=True)
    mapping.add_argument("--target", default="")
    mapping.set_defaults(func=map_disk)
    return result


if __name__ == "__main__":
    parsed = parser().parse_args()
    parsed.func(parsed)
