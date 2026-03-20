# ============================================================================ #
"""
Recovery helpers for reinstalling or aliasing missing manifest-requested extensions.

Author: XtremeXSPC
Version:
"""
# ============================================================================ #

from __future__ import annotations

import json
import subprocess
from dataclasses import dataclass
from pathlib import Path

from vscode_config import DEFAULT_EXTENSION_EXCLUDE_PATTERNS, VscodePathsConfig
from vscode_fs import canonicalize_path
from vscode_models import ExtensionInstall
from vscode_planner import is_excluded_extension
from vscode_profiles import is_preserved_missing_profile_decision, plan_manifest_repairs
from vscode_scanner import parse_extension_folder_name, scan_extension_root
from vscode_sync_apply import apply_extension_setup
from vscode_versions import compare_versions


@dataclass(frozen=True, slots=True)
class RecoveryRequest:
    """Represent one missing extension request inferred from a manifest entry."""

    manifest_path: Path
    entry_index: int
    edition: str
    source_kind: str
    extension_id: str
    version: str | None
    folder_name: str
    install_root: Path
    installer: str
    profile_name: str | None = None

    @property
    def install_spec(self) -> str:
        """Return the extension spec suitable for a CLI install command."""
        if self.version:
            return f"{self.extension_id}@{self.version}"
        return self.extension_id

    def to_dict(self) -> dict[str, str | int | None]:
        """Serialize the recovery request into a JSON-friendly mapping."""
        return {
            "manifest_path": str(self.manifest_path),
            "entry_index": self.entry_index,
            "edition": self.edition,
            "source_kind": self.source_kind,
            "extension_id": self.extension_id,
            "version": self.version,
            "folder_name": self.folder_name,
            "install_root": str(self.install_root),
            "installer": self.installer,
            "profile_name": self.profile_name,
            "install_spec": self.install_spec,
        }


@dataclass(frozen=True, slots=True)
class RecoveryInstallTask:
    """Represent one CLI install action needed by the recovery workflow."""

    installer: str
    install_root: Path
    extension_id: str
    version: str | None
    request_count: int
    profile_name: str | None = None

    @property
    def install_spec(self) -> str:
        """Return the extension spec suitable for a CLI install command."""
        if self.version:
            return f"{self.extension_id}@{self.version}"
        return self.extension_id

    def to_dict(self) -> dict[str, str | int | None]:
        """Serialize the install task into a JSON-friendly mapping."""
        return {
            "installer": self.installer,
            "install_root": str(self.install_root),
            "extension_id": self.extension_id,
            "version": self.version,
            "request_count": self.request_count,
            "profile_name": self.profile_name,
            "install_spec": self.install_spec,
        }


@dataclass(frozen=True, slots=True)
class RecoveryAliasTask:
    """Represent one compatibility alias to create for a missing folder name."""

    alias_path: Path
    target_path: Path
    extension_id: str
    folder_name: str

    def to_dict(self) -> dict[str, str]:
        """Serialize the alias task into a JSON-friendly mapping."""
        return {
            "alias_path": str(self.alias_path),
            "target_path": str(self.target_path),
            "extension_id": self.extension_id,
            "folder_name": self.folder_name,
        }


@dataclass(frozen=True, slots=True)
class RecoveryPlan:
    """Capture the recovery work needed for missing manifest-requested installs."""

    stable_dir: Path
    insiders_dir: Path
    requests: tuple[RecoveryRequest, ...]
    install_tasks: tuple[RecoveryInstallTask, ...]
    alias_tasks: tuple[RecoveryAliasTask, ...]

    def to_dict(self) -> dict[str, object]:
        """Serialize the recovery plan into a JSON-friendly mapping."""
        return {
            "stable_dir": str(self.stable_dir),
            "insiders_dir": str(self.insiders_dir),
            "request_count": len(self.requests),
            "install_task_count": len(self.install_tasks),
            "alias_task_count": len(self.alias_tasks),
            "requests": [request.to_dict() for request in self.requests],
            "install_tasks": [task.to_dict() for task in self.install_tasks],
            "alias_tasks": [task.to_dict() for task in self.alias_tasks],
        }


@dataclass(frozen=True, slots=True)
class RecoveryApplyReport:
    """Summarize the result of applying a missing-extension recovery plan."""

    attempted_installs: tuple[str, ...]
    successful_installs: tuple[str, ...]
    failed_installs: tuple[str, ...]
    created_aliases: tuple[Path, ...]
    failed_aliases: tuple[Path, ...]
    setup_linked_count: int
    setup_relinked_count: int
    setup_migrated_count: int

    def to_dict(self) -> dict[str, object]:
        """Serialize the recovery apply report into a JSON-friendly mapping."""
        return {
            "attempted_installs": list(self.attempted_installs),
            "successful_installs": list(self.successful_installs),
            "failed_installs": list(self.failed_installs),
            "created_aliases": [str(path) for path in self.created_aliases],
            "failed_aliases": [str(path) for path in self.failed_aliases],
            "setup_linked_count": self.setup_linked_count,
            "setup_relinked_count": self.setup_relinked_count,
            "setup_migrated_count": self.setup_migrated_count,
        }


def _load_manifest_item(manifest_path: Path, entry_index: int) -> dict | None:
    """Load a single manifest item by index from an ``extensions.json`` file."""
    payload = json.loads(manifest_path.read_text(encoding="utf-8"))
    if not isinstance(payload, list):
        return None
    if entry_index < 0 or entry_index >= len(payload):
        return None
    item = payload[entry_index]
    if not isinstance(item, dict):
        return None
    return item


def _profile_name_map_for_root(profile_root: Path) -> dict[str, str]:
    """Build a profile-id to profile-name map for one VS Code profile root."""
    user_root = profile_root.parent
    storage_path = user_root / "globalStorage" / "storage.json"
    if not storage_path.is_file():
        return {}

    try:
        payload = json.loads(storage_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}

    if not isinstance(payload, dict):
        return {}

    profiles_payload = payload.get("userDataProfiles")
    if not isinstance(profiles_payload, list):
        return {}

    mapping: dict[str, str] = {}
    for item in profiles_payload:
        if not isinstance(item, dict):
            continue
        location = item.get("location")
        name = item.get("name")
        if isinstance(location, str) and location.strip() and isinstance(name, str) and name.strip():
            mapping[location.strip()] = name.strip()
    return mapping


def _profile_name_maps(config: VscodePathsConfig) -> tuple[dict[str, str], dict[str, str]]:
    """Collect profile-name maps for Stable and Insiders profile roots."""
    stable_map: dict[str, str] = {}
    insiders_map: dict[str, str] = {}

    for root in config.stable_profile_roots:
        if root.is_dir():
            stable_map.update(_profile_name_map_for_root(root))
    for root in config.insiders_profile_roots:
        if root.is_dir():
            insiders_map.update(_profile_name_map_for_root(root))

    return stable_map, insiders_map


def _requested_version(item: dict | None, folder_name: str) -> str | None:
    """Determine which extension version a manifest entry is asking for."""
    if item:
        version = item.get("version")
        if isinstance(version, str) and version.strip():
            return version.strip()
    return parse_extension_folder_name(folder_name).version


def _current_manifest_root(edition: str, stable_root: Path, insiders_root: Path) -> Path:
    """Return the install root associated with a manifest edition string."""
    return stable_root if edition == "stable" else insiders_root


def _install_context(
    *,
    extension_id: str,
    folder_name: str,
    exclude_patterns: tuple[str, ...],
    stable_root: Path,
    insiders_root: Path,
) -> tuple[str, Path]:
    """Choose the installer binary and target root for a recovery request."""
    if is_excluded_extension(folder_name, exclude_patterns) or is_excluded_extension(
        f"{extension_id}-candidate",
        exclude_patterns,
    ):
        return ("code-insiders", insiders_root)
    return ("code", stable_root)


def _select_best_install(
    installs: list[ExtensionInstall],
    *,
    extension_id: str,
    requested_version: str | None,
) -> ExtensionInstall | None:
    """Select the best currently installed candidate for a recovery request."""
    candidates = [
        install
        for install in installs
        if install.extension_id == extension_id and install.target_exists
    ]
    if not candidates:
        return None

    exact_matches = [
        install
        for install in candidates
        if requested_version and install.version == requested_version
    ]
    if exact_matches:
        candidates = exact_matches

    best = candidates[0]
    for install in candidates[1:]:
        if best.is_symlink and not install.is_symlink:
            best = install
            continue
        if install.is_symlink == best.is_symlink:
            cmp = compare_versions(install.version, best.version)
            if cmp > 0:
                best = install
                continue
            if cmp == 0 and (install.mtime or 0) > (best.mtime or 0):
                best = install
    return best


def _build_alias_tasks(
    requests: tuple[RecoveryRequest, ...],
    *,
    stable_root: Path,
    insiders_root: Path,
) -> tuple[RecoveryAliasTask, ...]:
    """Build alias tasks for requests already satisfiable by existing installs."""
    stable_installs = scan_extension_root(stable_root)
    insiders_installs = scan_extension_root(insiders_root)

    alias_tasks: dict[tuple[Path, Path], RecoveryAliasTask] = {}
    for request in requests:
        install_root = request.install_root
        install_candidates = stable_installs if install_root == stable_root else insiders_installs
        target = _select_best_install(
            install_candidates,
            extension_id=request.extension_id,
            requested_version=request.version,
        )
        if not target:
            continue

        alias_path = install_root / request.folder_name
        if canonicalize_path(target.path) == canonicalize_path(alias_path):
            continue

        alias_tasks[(alias_path, target.path)] = RecoveryAliasTask(
            alias_path=alias_path,
            target_path=target.path,
            extension_id=request.extension_id,
            folder_name=request.folder_name,
        )

    return tuple(sorted(alias_tasks.values(), key=lambda task: (str(task.alias_path), str(task.target_path))))


def plan_missing_extension_recovery(
    stable_dir: str | Path,
    insiders_dir: str | Path,
    *,
    config: VscodePathsConfig | None = None,
    exclude_patterns: tuple[str, ...] | list[str] | None = None,
) -> RecoveryPlan:
    """Plan installs and aliases needed to satisfy missing manifest references."""
    resolved_config = config or VscodePathsConfig.from_home()
    stable_root = canonicalize_path(stable_dir)
    insiders_root = canonicalize_path(insiders_dir)
    resolved_patterns = tuple(exclude_patterns or DEFAULT_EXTENSION_EXCLUDE_PATTERNS)
    stable_profile_names, insiders_profile_names = _profile_name_maps(resolved_config)

    manifest_plan = plan_manifest_repairs(
        stable_root,
        insiders_root,
        config=resolved_config,
        exclude_patterns=resolved_patterns,
    )

    requests: list[RecoveryRequest] = []
    seen_requests: set[tuple[Path, int]] = set()
    stable_installs = scan_extension_root(stable_root)
    insiders_installs = scan_extension_root(insiders_root)

    for decision in manifest_plan.decisions:
        if decision.source_kind not in {"profile", "root"}:
            continue
        if not decision.current_folder_name or not decision.extension_id:
            continue

        manifest_root = _current_manifest_root(decision.edition.value, stable_root, insiders_root)
        current_path = manifest_root / decision.current_folder_name
        if current_path.exists():
            continue

        if not (
            decision.action.value == "update" or is_preserved_missing_profile_decision(decision)
        ):
            continue

        request_key = (decision.manifest_path, decision.entry_index)
        if request_key in seen_requests:
            continue
        seen_requests.add(request_key)

        item = _load_manifest_item(decision.manifest_path, decision.entry_index)
        version = _requested_version(item, decision.current_folder_name)
        installer, install_root = _install_context(
            extension_id=decision.extension_id,
            folder_name=decision.current_folder_name,
            exclude_patterns=resolved_patterns,
            stable_root=stable_root,
            insiders_root=insiders_root,
        )
        profile_name = None
        if decision.source_kind == "profile":
            profile_id = decision.manifest_path.parent.name
            if decision.edition.value == "stable":
                profile_name = stable_profile_names.get(profile_id)
            else:
                profile_name = insiders_profile_names.get(profile_id)

        requests.append(
            RecoveryRequest(
                manifest_path=decision.manifest_path,
                entry_index=decision.entry_index,
                edition=decision.edition.value,
                source_kind=decision.source_kind,
                extension_id=decision.extension_id,
                version=version,
                folder_name=decision.current_folder_name,
                install_root=install_root,
                installer=installer,
                profile_name=profile_name,
            )
        )

    install_requests: dict[tuple[str, Path, str, str | None], int] = {}
    for request in requests:
        candidate_pool = stable_installs if request.install_root == stable_root else insiders_installs
        candidate = _select_best_install(
            candidate_pool,
            extension_id=request.extension_id,
            requested_version=request.version,
        )
        if candidate:
            continue
        key = (
            request.installer,
            request.install_root,
            request.extension_id,
            request.version,
            request.profile_name,
        )
        install_requests[key] = install_requests.get(key, 0) + 1

    install_tasks = tuple(
        sorted(
            (
                RecoveryInstallTask(
                    installer=installer,
                    install_root=install_root,
                    extension_id=extension_id,
                    version=version,
                    request_count=count,
                    profile_name=profile_name,
                )
                for (installer, install_root, extension_id, version, profile_name), count in install_requests.items()
            ),
            key=lambda task: (
                task.installer,
                str(task.install_root),
                task.extension_id,
                task.version or "",
                task.profile_name or "",
            ),
        )
    )

    alias_tasks = _build_alias_tasks(
        tuple(sorted(requests, key=lambda request: (str(request.manifest_path), request.entry_index))),
        stable_root=stable_root,
        insiders_root=insiders_root,
    )

    return RecoveryPlan(
        stable_dir=stable_root,
        insiders_dir=insiders_root,
        requests=tuple(sorted(requests, key=lambda request: (str(request.manifest_path), request.entry_index))),
        install_tasks=install_tasks,
        alias_tasks=alias_tasks,
    )


def _safe_replace_alias(alias_path: Path, target_path: Path, *, root: Path) -> bool:
    """Create or replace a compatibility alias inside a managed root."""
    if alias_path != root and root not in alias_path.parents:
        return False
    if target_path != root and root not in target_path.parents:
        return False

    alias_path.parent.mkdir(parents=True, exist_ok=True)
    if alias_path.is_symlink():
        alias_path.unlink()
    elif alias_path.exists():
        return False
    alias_path.symlink_to(target_path)
    return True


def _run_install_task(task: RecoveryInstallTask) -> bool:
    """Run one recovery install task and report whether it succeeded."""
    specs = [task.install_spec]
    if task.version:
        specs.append(task.extension_id)

    attempted: set[str] = set()
    for install_spec in specs:
        if install_spec in attempted:
            continue
        attempted.add(install_spec)
        command = [
            task.installer,
            "--extensions-dir",
            str(task.install_root),
        ]
        if task.profile_name:
            command.extend(["--profile", task.profile_name])
        command.extend(
            [
                "--install-extension",
                install_spec,
                "--force",
            ]
        )
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=90)
        except subprocess.TimeoutExpired:
            continue
        if result.returncode == 0:
            return True
        if "already installed" in f"{result.stdout}\n{result.stderr}".lower():
            return True
    return False


def apply_missing_extension_recovery(
    plan: RecoveryPlan,
    *,
    config: VscodePathsConfig | None = None,
    exclude_patterns: tuple[str, ...] | list[str] | None = None,
) -> RecoveryApplyReport:
    """Apply a recovery plan and then reconcile the shared Insiders symlink state."""
    resolved_config = config or VscodePathsConfig.from_home()
    resolved_patterns = tuple(exclude_patterns or DEFAULT_EXTENSION_EXCLUDE_PATTERNS)
    attempted_installs: list[str] = []
    successful_installs: list[str] = []
    failed_installs: list[str] = []

    for task in plan.install_tasks:
        attempted_installs.append(task.install_spec)
        if _run_install_task(task):
            successful_installs.append(task.install_spec)
        else:
            failed_installs.append(task.install_spec)

    alias_tasks = _build_alias_tasks(
        plan.requests,
        stable_root=plan.stable_dir,
        insiders_root=plan.insiders_dir,
    )

    created_aliases: list[Path] = []
    failed_aliases: list[Path] = []
    for task in alias_tasks:
        root = plan.stable_dir if plan.stable_dir in task.alias_path.parents else plan.insiders_dir
        if task.alias_path.exists() and not task.alias_path.is_symlink():
            continue
        if _safe_replace_alias(task.alias_path, task.target_path, root=root):
            created_aliases.append(task.alias_path)
        else:
            failed_aliases.append(task.alias_path)

    setup_report = apply_extension_setup(
        plan.stable_dir,
        plan.insiders_dir,
        config=resolved_config,
        exclude_patterns=resolved_patterns,
    )

    return RecoveryApplyReport(
        attempted_installs=tuple(attempted_installs),
        successful_installs=tuple(successful_installs),
        failed_installs=tuple(failed_installs),
        created_aliases=tuple(created_aliases),
        failed_aliases=tuple(failed_aliases),
        setup_linked_count=setup_report.linked_count,
        setup_relinked_count=setup_report.relinked_count,
        setup_migrated_count=setup_report.migrated_count,
    )
