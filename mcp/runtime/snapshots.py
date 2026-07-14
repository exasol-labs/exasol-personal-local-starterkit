"""Snapshot creation and restore services."""

from __future__ import annotations

import json
from pathlib import Path
import uuid

from mcp.core.models import ChangeKind, ChangeRecord, OwnershipState, utc_now
from .filesystem import FileSystem
from .manifest import ManifestRepository
from .paths import RuntimePaths


class SnapshotRepository:
    """Store and restore point-in-time backups for managed files."""

    def __init__(
        self,
        paths: RuntimePaths,
        manifest_repository: ManifestRepository,
        filesystem: FileSystem | None = None,
    ) -> None:
        self._paths = paths
        self._manifest_repository = manifest_repository
        self._filesystem = filesystem or FileSystem()

    def create_snapshot(
        self,
        operation: str,
        artifact_paths: list[Path],
        label: str | None = None,
    ) -> dict:
        self._paths.ensure()
        snapshot_id = str(uuid.uuid4())
        snapshot_dir = self._paths.backups_dir / snapshot_id
        artifacts_dir = snapshot_dir / "artifacts"
        self._filesystem.ensure_dir(artifacts_dir)
        files = []
        for index, artifact_path in enumerate(sorted(set(artifact_paths))):
            if not artifact_path.exists():
                continue
            backup_name = f"{index:03d}_{artifact_path.name}"
            backup_target = artifacts_dir / backup_name
            self._filesystem.copy_file(artifact_path, backup_target)
            files.append(
                {
                    "path": str(artifact_path),
                    "backup_name": backup_name,
                    "permissions": self._filesystem.mode_string(artifact_path),
                }
            )
        snapshot_record = {
            "snapshot_id": snapshot_id,
            "created_at": utc_now(),
            "operation": operation,
            "label": label,
            "files": files,
            "manifest_hash": self._manifest_repository.manifest_hash(),
        }
        metadata_path = snapshot_dir / "snapshot.json"
        self._filesystem.write_text(
            metadata_path, json.dumps(snapshot_record, indent=2, sort_keys=True) + "\n"
        )
        self._manifest_repository.add_snapshot(snapshot_record)
        return snapshot_record

    def load_snapshot(self, snapshot_id: str) -> dict:
        metadata_path = self._paths.backups_dir / snapshot_id / "snapshot.json"
        return self._filesystem.read_json(metadata_path)

    def restore_snapshot(self, snapshot_id: str) -> list[ChangeRecord]:
        snapshot = self.load_snapshot(snapshot_id)
        snapshot_dir = self._paths.backups_dir / snapshot_id / "artifacts"
        changes: list[ChangeRecord] = []
        for file_record in snapshot.get("files", []):
            source = snapshot_dir / file_record["backup_name"]
            target = Path(file_record["path"])
            self._filesystem.copy_file(source, target)
            changes.append(
                ChangeRecord(
                    kind=ChangeKind.RESTORE,
                    path=str(target),
                    ownership_state=OwnershipState.MANAGED,
                    applied=True,
                    reason="restore_snapshot",
                )
            )
        return changes
