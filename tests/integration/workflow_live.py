"""X1/DS5 live smoke: isolated descriptors/logs, actual local table and UDF, Cloud trace with a stub model.

Creates only acceptance-test scripts/views. Never changes source tables or their comments.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
import threading
from http.server import ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / "notebook/package"), str(ROOT / "packages/exasol-mlflow"), str(ROOT / "tests/lib")]
from stub_model_server import Handler


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--credentials-file", type=Path, required=True)
    parser.add_argument("--approve-test-writes", action="store_true")
    args = parser.parse_args(argv)
    if not args.approve_test_writes:
        parser.error("--approve-test-writes is required for acceptance schema/scripts and isolated descriptor approvals")
    if args.output_dir.exists() and any(args.output_dir.iterdir()):
        parser.error("Use a new empty output directory so prior evidence is preserved")
    keys = json.loads(args.credentials_file.read_text())
    if not all(keys.get(k) for k in ("LANGFUSE_PUBLIC_KEY", "LANGFUSE_SECRET_KEY", "LANGFUSE_BASE_URL")):
        parser.error("The private configuration needs all three Langfuse settings")
    import exakit.nb as nb
    from exakit_nb import _kit
    settings = {key: _kit.setting(key) for key in ("EXAKIT_NB_STORE", "EXAKIT_NB_MASTER_FILE")}
    actual_home = Path(os.environ.get("EXAKIT_HOME") or Path.home()/".exasol-starter-kit")
    output = args.output_dir.resolve(); output.mkdir(parents=True, exist_ok=True);output.chmod(0o700)
    home = output / "kit";home.mkdir(exist_ok=True)
    shutil.copyfile(actual_home / "manifest.json", home / "manifest.json");(home / "manifest.json").chmod(0o600)
    os.environ.update({k:v for k,v in settings.items() if v})
    os.environ.update(EXAKIT_HOME=str(home), EXAKIT_NB_KIT=str(ROOT), EXAKIT_NB_DATASETS=str(ROOT/"data/datasets"))
    conn = nb.connect()
    report = {"kind":"live-workflow-smoke", "passed":False}
    Handler.quiet = True
    server = ThreadingHTTPServer(("127.0.0.1",0), Handler)
    thread = threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    try:
        workflow = nb.workflow("acceptance-flow")
        draft = nb.describe("PHARMA.PHARMA_TRIALS", conn=conn, id="acceptance-pharma-flow")
        first = draft.approve(owner="acceptance-tests", comments=False, conn=conn)
        assert first.version == 1
        original_text = list(first.text_cols())
        assert len(original_text) > 1
        draft.set("text", original_text[:1])
        ds = draft.approve(owner="acceptance-tests", comments=False, conn=conn)
        assert ds.version == 2 and len(nb.list_versions(ds.id)) == 2
        sql = f"SELECT {ds.col('category')} AS CATEGORY, COUNT(*) AS N FROM {ds.fact_table} GROUP BY 1 ORDER BY 1"
        frame = nb.sql(conn,sql);nb.show_sql()
        assert len(frame)>0
        sample_sql = f"SELECT {ds.text_sql()} AS TEXT_ FROM {ds.fact_table} LIMIT 5"
        texts = nb.sql(conn,sample_sql)["TEXT_"].tolist()
        os.environ.update({k:keys[k] for k in ("LANGFUSE_PUBLIC_KEY","LANGFUSE_SECRET_KEY","LANGFUSE_BASE_URL")})
        os.environ.update(EXAKIT_MODEL_ID="stub", EXAKIT_PROVIDER_BASE_URL=f"http://127.0.0.1:{server.server_port}/v1/",
                          EXAKIT_PROVIDER_API_KEY="", EXAKIT_PROVIDER_HEADERS="")
        with nb.trace(conn,"acceptance-real-data",dataset=ds,sql=sample_sql) as span:
            client,model=nb.model_client()
            with client:
                for text in texts:
                    client.chat.completions.create(model=model,messages=[{"role":"user","content":str(text)[:1000]}])
            trace_id=span.trace_id
        from langfuse import Langfuse
        import time
        cloud=Langfuse(public_key=keys["LANGFUSE_PUBLIC_KEY"],secret_key=keys["LANGFUSE_SECRET_KEY"],base_url=keys["LANGFUSE_BASE_URL"])
        delivered=[]
        for attempt in range(30):
            observations=cloud.api.observations.get_many(trace_id=trace_id,limit=30,fields="basic,io,metadata,model,usage,metrics,trace_context").data
            delivered=[o for o in observations if o.type=="GENERATION"]
            if len(delivered)==5:break
            time.sleep(2)
        assert len(delivered)==5
        assert all((o.metadata or {}).get("exasol.workflow_id")==workflow for o in delivered)
        assert all((o.metadata or {}).get("exasol.session_id")==str(conn.session_id()) for o in delivered)
        cloud.shutdown()
        handoff_path=nb.write_handoff(conn,ds)
        handoff=nb.read_handoff(handoff_path)
        import exasol_mlflow
        from mlflow import MlflowClient
        uri="sqlite:///"+str(output/"tracking.db");os.environ["MLFLOW_TRACKING_URI"]=uri
        tracking=MlflowClient(tracking_uri=uri)
        tracking.create_experiment("acceptance-flow",artifact_location=(output/"artifacts").as_uri())
        conn.execute("CREATE SCHEMA IF NOT EXISTS EXAKIT_ACCEPTANCE")
        plan=nb.prepare_training(conn,ds,handoff,schema="EXAKIT_ACCEPTANCE",name="TRAIN_FLOW",container="PYTHON3_ML")
        conn.execute(plan.create_script)
        with exasol_mlflow.start_run(conn,params=plan.params,experiment="acceptance-flow",tags=ds.tags(),handoff=handoff) as run:
            run.execute(plan.training_sql)
        assert tracking.get_run(run.run_id).data.tags["exasol.workflow_id"]==workflow
        log=home/"workflows"/(workflow+".jsonl")
        events=[json.loads(line) for line in log.read_text().splitlines()]
        kinds={e["kind"] for e in events}
        assert {"describe.draft","describe.approve","sql","trace","handoff","mlflow.run"} <= kinds
        assert all(e["workflow_id"]==workflow for e in events)
        assert keys["LANGFUSE_SECRET_KEY"] not in log.read_text()
        report.update(passed=True,workflow_id=workflow,descriptor_versions=[1,2],event_kinds=sorted(kinds),
                      actual_database_session=True,mlflow_tag_verified=True,trace_metadata_verified=True,trace_id=trace_id,
                      training_run_id=run.run_id,descriptor_id=ds.id,sql=sql)
    finally:
        conn.close();server.shutdown();server.server_close();thread.join(timeout=3)
        (output/"result.json").write_text(json.dumps(report,indent=2)+"\n")
    return 0


if __name__=="__main__":raise SystemExit(main())
