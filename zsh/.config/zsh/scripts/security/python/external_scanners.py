#!/usr/bin/env python3

# ============================================================================ #
"""
Security Scan - External Scanner Wrappers:
Thin, defensive wrappers around ClamAV (`clamscan`) and YARA (`yara` CLI or
the `yara-python` module). Both are optional: callers should check the
`*_available()` helpers first and degrade gracefully (see cli.py), since
neither tool is assumed to be installed.

Install hints (macOS / Homebrew):
    brew install clamav      # then: freshclam   (fetch/update virus signatures)
    brew install yara

Author: Claude (Anthropic)
Version: 1.0.0
"""
# ============================================================================ #

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

from report import Finding, Severity, print_progress, print_status

_CLAMSCAN_TIMEOUT_PER_FILE = 60
_YARA_TIMEOUT_PER_FILE = 30


# ++++++++++++++++++++++++++++++++++ ClamAV ++++++++++++++++++++++++++++++++++ #


def clamav_available() -> bool:
    """Return True when a ClamAV scanning binary is on PATH."""
    return shutil.which("clamscan") is not None or shutil.which("clamdscan") is not None


def clamav_binary() -> str | None:
    """Prefer the daemon-backed `clamdscan` (much faster) over `clamscan`."""
    return shutil.which("clamdscan") or shutil.which("clamscan")


def run_clamav(
    paths: list[Path], *, show_progress: bool = True
) -> dict[Path, list[Finding]]:
    """Scan every path with ClamAV in a single batch invocation, streamed.

    Unlike a plain `subprocess.run(capture_output=True)` call — which blocks
    silently until the *entire* batch finishes — this reads clamscan's
    stdout line by line as it works, so large batches (hundreds/thousands of
    files) show live progress instead of appearing to hang.

    Returns a mapping of path -> findings. Paths with no entry were clean.
    """
    binary = clamav_binary()
    results: dict[Path, list[Finding]] = {}
    if binary is None or not paths:
        return results

    # Deliberately omit "-i" (infected-only) so every scanned file prints a
    # line ("... OK" or "... FOUND"), which is what lets us report progress.
    cmd = [binary, "--no-summary"] + [str(p) for p in paths]
    total = len(paths)
    scanned = 0

    try:
        # stderr is merged into stdout: a separate stderr pipe is never
        # drained during the streaming loop, so a chatty clamscan could fill
        # the pipe buffer and deadlock the scan.
        proc = subprocess.Popen(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1
        )
    except OSError as exc:
        for p in paths:
            results[p] = [
                Finding("clamav", Severity.WARNING, f"Could not run ClamAV: {exc}")
            ]
        return results

    assert proc.stdout is not None
    for line in proc.stdout:
        line = line.strip()
        if not line:
            continue

        if line.endswith("FOUND"):
            try:
                file_part, signature_part = line.rsplit(":", 1)
            except ValueError:
                continue
            signature = signature_part.strip().removesuffix("FOUND").strip()
            matched_path = Path(file_part.strip())
            scanned += 1
            print_status("warn", f"ClamAV: {matched_path} -> {signature}")
            results.setdefault(matched_path, []).append(
                Finding(
                    "clamav",
                    Severity.CRITICAL,
                    f"ClamAV signature match: {signature}",
                    detail={"signature": signature},
                )
            )
        elif line.endswith("OK"):
            scanned += 1

        if show_progress and scanned:
            print_progress(scanned, total, "ClamAV")

    try:
        proc.wait(timeout=_CLAMSCAN_TIMEOUT_PER_FILE * max(1, total))
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
        print_status("warn", "ClamAV timed out; results may be incomplete.")
        return results
    if proc.returncode not in (0, 1):
        print_status(
            "warn",
            f"ClamAV exited with status {proc.returncode}; results may be incomplete.",
        )
    return results


# +++++++++++++++++++++++++++++++++++ YARA +++++++++++++++++++++++++++++++++++ #


def yara_available() -> bool:
    """Return True when the YARA CLI is on PATH."""
    return shutil.which("yara") is not None


def run_yara(rules_path: Path, path: Path) -> list[Finding]:
    """Run YARA rules against a single file and return matches as findings."""
    if not yara_available():
        return []
    if not rules_path.exists():
        return [
            Finding("yara", Severity.WARNING, f"Rules file not found: {rules_path}")
        ]

    try:
        proc = subprocess.run(
            ["yara", "-w", str(rules_path), str(path)],
            capture_output=True,
            text=True,
            timeout=_YARA_TIMEOUT_PER_FILE,
        )
    except subprocess.TimeoutExpired:
        return [Finding("yara", Severity.WARNING, "YARA scan timed out for this file.")]
    except OSError as exc:
        return [Finding("yara", Severity.WARNING, f"Could not run YARA: {exc}")]

    findings: list[Finding] = []
    for line in proc.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        # Output format: "<rule_name> <file_path>"
        rule_name = line.split(" ", 1)[0]
        findings.append(
            Finding(
                "yara",
                Severity.CRITICAL,
                f"Matched YARA rule: {rule_name}",
                detail={"rule": rule_name},
            )
        )
    if proc.returncode not in (0,) and not findings and proc.stderr.strip():
        findings.append(
            Finding("yara", Severity.WARNING, f"yara stderr: {proc.stderr.strip()}")
        )
    return findings


# ============================================================================ #
# End of script.
