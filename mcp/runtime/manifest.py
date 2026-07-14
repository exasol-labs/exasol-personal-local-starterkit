"""Manifest repository for managed artifacts."""

from __future__ import annotations

import json
from pathlib import Path
import uuid

from mcp.core.models import ArtifactReference, utc_now
from mcp.core.serialization import sha256_text, to_primitive
from .filesystem import FileSystem
from .paths import RuntimePaths


class ManifestRepository:
    """Persist and update the subsystem manifest."""

    _UPSTREAM_COMPONENT_KEY = "mcp_server"
    _UPSTREAM_STATE_KEY = "managed_state"

    def __init__(
        self,
        paths: RuntimePaths,
        filesystem: FileSystem | None = None,
        subsystem_version: str = "0.1.0",
    ) -> None:
        self._paths = paths
        self._filesystem = filesystem or FileSystem()
        self._subsystem_version = subsystem_version

    def _empty_manifest(self) -> dict:
        now = utc_now()
        return {
            "schema_version": "1",
            "runtime_root": str(self._paths.runtime_root),
            "created_at": now,
            "updated_at": now,
            "subsystem_version": self._subsystem_version,
            "artifacts": [],
            "snapshots": [],
        }

    def _normalize_manifest(self, manifest: dict | None) -> dict:
        doc = dict(manifest or {})
        empty = self._empty_manifest()
        for key, value in empty.items():
            doc.setdefault(key, value)
        doc["artifacts"] = list(doc.get("artifacts", []))
        doc["snapshots"] = list(doc.get("snapshots", []))
        doc["runtime_root"] = str(self._paths.runtime_root)
        return doc

    @staticmethod
    def _is_upstream_manifest(document: dict) -> bool:
        return "manifest_version" in document and "schema_version" not in document

    def _load_root_document(self) -> dict | None:
        if not self._paths.manifest_path.exists():
            return None
        return self._filesystem.read_json(self._paths.manifest_path)

    def _exported_config_names(self, manifest: dict) -> list[str]:
        names = {
            Path(artifact["path"]).name
            for artifact in manifest.get("artifacts", [])
            if artifact.get("removed_at") is None
        }
        return sorted(names)

    def load(self) -> dict:
        self._paths.ensure()
        root_document = self._load_root_document()
        if root_document is None:
            return self._empty_manifest()
        if self._is_upstream_manifest(root_document):
            components = root_document.get("components", {})
            component_state = {}
            if isinstance(components, dict):
                mcp_component = components.get(self._UPSTREAM_COMPONENT_KEY, {})
                if isinstance(mcp_component, dict):
                    component_state = mcp_component.get(self._UPSTREAM_STATE_KEY, {}) or {}
            return self._normalize_manifest(component_state)
        return self._normalize_manifest(root_document)

    def save(self, manifest: dict) -> None:
        state = self._normalize_manifest(manifest)
        state["updated_at"] = utc_now()
        root_document = self._load_root_document()
        if root_document is not None and self._is_upstream_manifest(root_document):
            components = root_document.setdefault("components", {})
            if not isinstance(components, dict):
                components = {}
                root_document["components"] = components
            mcp_component = components.setdefault(self._UPSTREAM_COMPONENT_KEY, {})
            if not isinstance(mcp_component, dict):
                mcp_component = {}
                components[self._UPSTREAM_COMPONENT_KEY] = mcp_component
            mcp_component[self._UPSTREAM_STATE_KEY] = state
            mcp_component["configs"] = self._exported_config_names(state)
            mcp_component["export_dir"] = str(self._paths.mcp_dir)
            self._filesystem.write_json(self._paths.manifest_path, root_document)
            return
        self._filesystem.write_json(self._paths.manifest_path, state)

    def list_active_artifacts(self) -> list[dict]:
        return [
            artifact
            for artifact in self.load()["artifacts"]
            if artifact.get("removed_at") is None
        ]

    def manifest_hash(self) -> str:
        manifest = self.load()
        return sha256_text(json.dumps(manifest, sort_keys=True))

    def upsert_artifact(self, artifact: ArtifactReference) -> ArtifactReference:
        manifest = self.load()
        artifacts = manifest["artifacts"]
        now = utc_now()
        record = to_primitive(artifact)
        if not record.get("artifact_id"):
            record["artifact_id"] = str(uuid.uuid4())
        for existing in artifacts:
            if existing.get("removed_at") is not None:
                continue
            same_identity = (
                existing["client"] == record["client"]
                and existing["path"] == record["path"]
                and existing.get("metadata", {}).get("entry_name")
                == record.get("metadata", {}).get("entry_name")
            )
            if same_identity:
                record["artifact_id"] = existing["artifact_id"]
                record["created_at"] = existing.get("created_at") or now
                record["updated_at"] = now
                record["removed_at"] = None
                existing.update(record)
                self.save(manifest)
                return ArtifactReference(**existing)
        record["created_at"] = record.get("created_at") or now
        record["updated_at"] = now
        artifacts.append(record)
        self.save(manifest)
        return ArtifactReference(**record)

    def mark_removed(self, artifact_id: str) -> None:
        manifest = self.load()
        for artifact in manifest["artifacts"]:
            if artifact["artifact_id"] == artifact_id and artifact.get("removed_at") is None:
                artifact["removed_at"] = utc_now()
                artifact["updated_at"] = artifact["removed_at"]
        self.save(manifest)

    def add_snapshot(self, snapshot_record: dict) -> None:
        manifest = self.load()
        manifest["snapshots"].append(snapshot_record)
        self.save(manifest)

    def record_client_setup(self, setup: dict) -> None:
        root_document = self._load_root_document()
        if root_document is not None and self._is_upstream_manifest(root_document):
            components = root_document.setdefault("components", {})
            if not isinstance(components, dict):
                components = {}
                root_document["components"] = components
            mcp_component = components.setdefault(self._UPSTREAM_COMPONENT_KEY, {})
            if not isinstance(mcp_component, dict):
                mcp_component = {}
                components[self._UPSTREAM_COMPONENT_KEY] = mcp_component
            mcp_component["client_setup"] = dict(setup)
            self._filesystem.write_json(self._paths.manifest_path, root_document)
            return
        manifest = self.load()
        manifest["client_setup"] = dict(setup)
        self.save(manifest)

    def latest_snapshot_id(self) -> str | None:
        manifest = self.load()
        snapshots = manifest.get("snapshots", [])
        if not snapshots:
            return None
        return snapshots[-1]["snapshot_id"]
