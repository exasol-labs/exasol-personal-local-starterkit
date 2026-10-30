"""Live DS4.4 contract: actual Langfuse, five synthetic calls to a loopback stub, no paid model.

Use LANGFUSE_* or --credentials-file pointing to a private JSON file. Reports
contain no keys, provider endpoint or account-specific project URL.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import time
import types
from http.server import ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / "notebook/package"), str(ROOT / "tests/lib")]
from stub_model_server import Handler


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--credentials-file", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    if args.credentials_file:
        doc = json.loads(args.credentials_file.read_text())
        for key in ("LANGFUSE_PUBLIC_KEY", "LANGFUSE_SECRET_KEY", "LANGFUSE_BASE_URL"):
            os.environ[key] = doc[key]
    if not all(os.environ.get(key) for key in ("LANGFUSE_PUBLIC_KEY", "LANGFUSE_SECRET_KEY", "LANGFUSE_BASE_URL")):
        parser.error("Configure all three LANGFUSE_* settings; never place keys in command arguments.")
    Handler.quiet = True
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    report = {"kind": "live-langfuse-stub-model", "passed": False}
    try:
        with tempfile.TemporaryDirectory(prefix="exakit-langfuse-") as home:
            os.environ.update(EXAKIT_HOME=home, EXAKIT_MODEL_ID="stub",
                              EXAKIT_PROVIDER_BASE_URL=f"http://127.0.0.1:{server.server_port}/v1/",
                              EXAKIT_PROVIDER_API_KEY="", EXAKIT_PROVIDER_HEADERS="")
            import exakit.nb as nb
            workflow_id = nb.workflow("langfuse-integration")
            sql = "SELECT NOTE FROM ACCEPTANCE.SYNTHETIC_RECORDS LIMIT 5"
            dataset = types.SimpleNamespace(id="synthetic", version=1, digest="fixture-descriptor-digest",
                tags=lambda: {"exasol.dataset": "synthetic", "exasol.descriptor_version": "1",
                              "exasol.descriptor": "fixture-descriptor-digest"})
            conn = types.SimpleNamespace(session_id=lambda: "acceptance-session")
            with nb.trace(conn, "acceptance-text-step", dataset=dataset, sql=sql) as span:
                client, model = nb.model_client()
                with client:
                    for n in range(5):
                        client.chat.completions.create(model=model, messages=[
                            {"role": "user", "content": f"Synthetic acceptance description {n}."}])
                trace_id = span.trace_id
            from langfuse import Langfuse
            cloud = Langfuse(public_key=os.environ["LANGFUSE_PUBLIC_KEY"], secret_key=os.environ["LANGFUSE_SECRET_KEY"],
                             base_url=os.environ["LANGFUSE_BASE_URL"])
            generations = []
            for attempt in range(30):
                observations = cloud.api.observations.get_many(
                    trace_id=trace_id, limit=30, fields="basic,io,metadata,model,usage,metrics,trace_context").data
                generations = [o for o in observations if o.type == "GENERATION"]
                if len(generations) == 5:
                    break
                time.sleep(2)
            assert len(generations) == 5, "Expected five delivered generations"
            serialized = json.dumps([o.model_dump() for o in observations], default=str)
            assert os.environ["LANGFUSE_SECRET_KEY"] not in serialized
            assert workflow_id in serialized and "synthetic" in serialized and "acceptance-session" in serialized
            assert sql in serialized and "fixture-descriptor-digest" in serialized
            for generation in generations:
                assert generation.input and generation.output, "Missing input/output"
                assert generation.start_time and generation.end_time, "Missing timing"
                assert generation.usage_details, "Missing token usage"
            cloud.shutdown()
            report.update(passed=True, generations=len(generations), workflow_linked=True,
                          input_output=True, timing=True, token_usage=True, secret_absent=True)
    finally:
        server.shutdown(); server.server_close(); thread.join(timeout=3)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
