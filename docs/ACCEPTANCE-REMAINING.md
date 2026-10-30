# Acceptance evidence and remaining steps

The implementation includes repeatable checks, but release acceptance still needs
machine, service and participant evidence. Keep the internal changes document
local. This guide contains no account keys and does not cover virtual schemas or
external data-source connections; those remain with their existing owner.

## What the local checks establish

| Check | Evidence and limit |
|---|---|
| Shared workflow | Real table profiling and approvals v1/v2, exploration, five stub-model calls delivered to Langfuse Cloud, handoff and real Python UDF training share one workflow ID. Both descriptor versions remain. |
| Credential protection | Nested and JSON-encoded credential metadata is refused before workflow writes. Generated text artifacts can be scanned against the active kit's connection values and configured secrets before upload. This is not a proof against arbitrary unlabelled secret text. |
| Missing roles | Explore skips affected queries, text, modeling or handoff steps and states which roles are missing. Steps with their required roles still run. |
| Training | Two real UDF runs per reference recipe produced equal metrics and coefficient digests. Pharma with `CLASS_WEIGHT = None`: macro-F1 0.445955 versus majority 0.441129. Banking with `"balanced"`: 0.523298 versus 0.469807. Unweighted Banking still matches its baseline. |
| Langfuse | Five synthetic generations with input/output, token usage, timing and workflow metadata were verified against Cloud and disposable self-hosted 4.59.0. The combined workflow additionally verified the real database session ID. |
| MLflow | Real authenticated HTTP servers at 3.0.0 and 3.17.2 passed metric/artifact, unauthorized-access, pre-query outage and mid-run spool/replay checks. These service tests use fixture UDF rows; the combined workflow separately exercises a real UDF. |
| Model comparison | Protocol 2 evaluated two installed Ollama models on ten reference questions per dataset through read-only MCP. Both `qwen2.5:0.5b` and `llama3.2:latest` scored 0/20 exact result matches. The benchmark works; these results do not establish acceptable SQL quality. |
| Notebook execution | All eight persona notebooks completed on both reference datasets locally. Additional full held-out comparisons used all 1,030 Pharma and 1,317 Banking test rows with no limit: maximum gaps 2.432e-14 and 1.111e-16; every label agrees and all probabilities are finite. Model-file scoring also matched. All 16 executed notebook files passed the output privacy scan. Windows and human interaction remain separate gates. |
| Share | A responsive Dash Server preview with category/search filters, Top N, sorting, reset, two charts, summary cards and a paginated/exportable table passed health checks and returned reference counts. A person must compare its figures and explicitly approve promotion. |

Dates, exact run IDs and machine-specific evidence belong in the internal record.
A passed service fixture or warm-machine notebook run does not establish every
end-to-end acceptance criterion.

## 1. Finish the current Mac walkthrough

1. Use [MANUAL-RUNBOOK.md](MANUAL-RUNBOOK.md), starting from the checkout directory.
   `EXAKIT_LOCAL_KIT="$PWD"` must point to that checkout, not your home folder.
2. Run the four Data Scientist notebooks on Pharma, then Banking. Keep optional
   AI off first; configure a model and enable themes explicitly for the second pass.
3. Start a workflow in Quickstart and paste its ID into subsequent notebooks.
   Review the role evidence and approve before Ask, training or Share.
4. Use the two training recipes above. Keep the same temporal split and seed;
   repeat each twice and retain metrics, coefficient digest and MLflow tags.
5. Run Rust scoring and the model-file scoring lesson. For these fixed reference snapshots, set `TEST_ROWS = 10_000` to include the entire held-out partition; the ordinary quick check caps it at 500. Check labels and maximum
   probability difference rather than accepting a successful deployment alone.
   Rust's bucketless fallback packages the library into a verified runtime;
   it requires explicit restart consent. Leave `ALLOW_DATABASE_RESTART = False`
   until a database restart is acceptable.
6. In Share, open the preview, compare its categories and counts with the printed
   SQL, then set `FIGURES_CHECKED = True` and run promotion. Preserve the live
   URL, revision, descriptor version and query digest as evidence.
7. Repeat Explore on a synthetic CSV with different column names. Complete the
   role review first, then change only `DATASET` in Explore; retain the executed
   notebook and descriptor. This tests the generic path, not a reference-only demo.
8. Run Jupyter and Marimo interactively and the four useful lessons. Existing
   edited notebook copies are preserved by updates; open a fresh current copy.

An empty Personal bucket may need its first file before the VM exposes the
folder. `check_bucket` now creates a non-model `.exakit-bucket` marker and retries
briefly. If it still fails, keep the failure evidence and inspect the launcher
mapping; do not silently bypass the check.

## 2. Reproduce service checks locally

Run from a checkout with the kit's notebook Python, or a disposable environment
containing the dependencies listed in `acceptance-services.yml`.

```sh
KIT_PY="$HOME/.exasol-starter-kit/notebook-venv/bin/python"
"$KIT_PY" tests/integration/langfuse_live.py \
  --credentials-file "$HOME/.exasol-starter-kit/credentials/langfuse.json" \
  --output /tmp/langfuse-cloud.json
"$KIT_PY" tests/integration/with_langfuse.py --output /tmp/langfuse-selfhost.json
"$KIT_PY" tests/integration/mlflow_live.py --output /tmp/mlflow-service.json
```

The Cloud command sends synthetic text to the project in that private settings
file. The self-hosted command needs Docker Compose, downloads the pinned official
compose file and creates then removes only its disposable project and volumes.
The MLflow command starts an authenticated test server on a free loopback port,
interrupts that owned server, restarts it and verifies replay. It leaves the
user's managed MLflow service alone.

To reproduce actual database lineage, use a new empty output directory:

```sh
"$KIT_PY" tests/integration/workflow_live.py \
  --credentials-file "$HOME/.exasol-starter-kit/credentials/langfuse.json" \
  --output-dir /tmp/exakit-workflow-check \
  --approve-test-writes
```

This creates acceptance scripts/views and isolated descriptors/logs, reads the
public Pharma reference table and sends five sampled texts to the configured
Langfuse project through the stub model. It preserves source rows and comments.
Do not upload the entire output directory: its private manifest copy is local
connection configuration. Share only the sanitized `result.json`.

## 3. Evaluate a useful SQL model

1. Choose an exact model supported by your provider or local server using
   [MODEL-PROVIDERS.md](../notebook/MODEL-PROVIDERS.md). Configure credentials
   privately in the environment; never put keys in a notebook or commit.
2. Run the benchmark after authorizing its generated read-only queries:

```sh
KIT_PY="$HOME/.exasol-starter-kit/notebook-venv/bin/python"
"$KIT_PY" tools/ask_benchmark.py \
  --model '<exact-model-id>' --timeout 30 --max-output-tokens 1024 \
  --approve-proposals --output /tmp/ask-model-scores.json
```

Repeat `--model` to compare models on the same twenty questions. The prompt
contains schema and required output column names, never reference SQL/results.
The comparison preserves column positions and duplicates while ignoring aliases
and row order. A reference failure invalidates the evaluation; a model failure
scores zero. There is no automatic model selection when every score is zero.

3. Review failed questions and proposed SQL. Choose the best measured model for
   participant gate G3 only after it gives useful, checked answers. A successful
   connection or JSON response is insufficient. Paid APIs require your own key
   and may incur charges; none is needed for local model testing.

## 4. Enable hosted evidence

1. The repository owner must resolve the GitHub Actions billing/spending-limit
   block. A check that never starts is not a passing check.
2. After the workflows are present on the default branch, dispatch them on the
   candidate branch. GitHub may not list a newly added manual workflow before
   it exists on the default branch; do not merge merely to manufacture a pass.
3. Run the normal Versions workflow for unit, shell, dataset and core notebook
   checks. Retain the run URL and commit SHA.
4. Run **Service acceptance contracts**. For its optional Cloud job, create a
   dedicated CI Langfuse project, add repository secrets `LANGFUSE_PUBLIC_KEY`
   and `LANGFUSE_SECRET_KEY`, and variable `LANGFUSE_BASE_URL`. Enable the Cloud
   input. Do not reuse personal keys without the project owner's approval.
5. Register a dedicated trusted Mac/Linux self-hosted runner with label
   `exakit-acceptance`. It needs the kit, both reference datasets, read-only MCP,
   Python and Rust UDF runtimes, Docker/Podman, MLflow and Dash Server. Do not
   attach a personal database to untrusted pull-request execution.
6. Dispatch **Full local notebook acceptance** on that runner. Allow restart
   only for a disposable acceptance database. It binds the checked-out helper and CLI code in a temporary kernel, runs all eight persona
   notebooks, leaves Share at preview, and uploads executed notebooks only
   after the credential scan passes. A failed privacy scan suppresses upload.
7. Dispatch **Ask model evaluation** with the chosen installed model IDs. Keep
   its scores, then run the separate human figure and participant checks.

## 5. Collect the remaining release decisions

| Owner | Steps and evidence |
|---|---|
| Dataset owner | Review source terms and redistribution for each snapshot. Record approval and only then change `terms.confirmed`; the implementation leaves both false. |
| Mac and Windows testers | On clean gate machines, record RAM/OS, install start and first connected result. DS: under 10 minutes Mac / 15 Windows. ML: under 15 minutes. Each reference dataset: under 5 minutes. Warm installs do not count. Windows live verification was deferred by the user. |
| Notebook maintainer | Run a connector 3.1.0 example unchanged end to end. The existing connection-cell check establishes connection compatibility only. A full example requiring external data needs the responsible owner's agreed test. Verify connection refresh after container installation and a port change. |
| Runtime owner | Confirm host bucket read/write visibility on both gate platforms, a real artifact above 1 MB, Python/Rust parity, fallback restart consent/reuse and actual UDF network-egress-disabled training. Preserve failure evidence and identify launcher constraints. |
| G1 facilitator | Use `tests/manual/gate-g1.md` with uncoached participants. Capture own-file swap, role approval/first query within 8 minutes and finding a trace in their own project; record the two-of-three completion gate. |
| G2 facilitator | Use `tests/manual/gate-g2.md`; capture training, MLflow artifacts, Rust scoring and the two-of-three completion gate within 45 minutes. |
| G3 facilitator | Use the documented Ask/Share gate with the best measured model; capture two-of-three completion within 20 minutes and human dashboard figure approval. |
| External-source owner | Supply virtual-table/federation evidence separately, including generic exploration, role comments and bounded profiling. This task makes no changes to that implementation. |

The archived Governed SQL MCP server was evaluated: its repository directs users
to the official Exasol MCP server. The kit drafts proposals itself and executes
approved SQL through that server's dedicated read-only identity. See the
[archived repository](https://github.com/exasol-labs/exasol-labs-text2sql-mcp-server)
and [official server](https://github.com/exasol/mcp-server).
