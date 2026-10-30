# Connect a text model and trace its calls

The same three names configure Explore, optional Ask SQL drafting and optional
column notes. The kit supplies a client for **text Chat Completions**. You choose
the server and a model it actually serves; model weights are not bundled.

| Setting | Meaning |
|---|---|
| `EXAKIT_MODEL_ID` | Exact model identifier accepted by your provider/server |
| `EXAKIT_PROVIDER_BASE_URL` | API base URL, including its version/prefix; not a full request URL |
| `EXAKIT_PROVIDER_API_KEY` | Provider credential; leave unset only if that server allows unauthenticated calls |
| `EXAKIT_PROVIDER_HEADERS` | Optional JSON map of additional routing headers; omit unless required |

No model ID means optional AI stays disabled. A selected model requires an
explicit base URL. Blank keys use a non-secret SDK placeholder for unauthenticated
servers. Embedded URL credentials, query/fragment parameters and full request
paths such as `/chat/completions` are refused. Authentication belongs in the key
setting, not custom `Authorization`, `api-key` or `x-api-key` headers.

Every call passes the selected base URL and key explicitly to the SDK. Unrelated
SDK environment credentials do not supply either value. Settings are read on
each call; a new Terminal environment does not change an already-running kernel.
Restart notebook servers from that Terminal, or set the variables in that kernel.
Do not print environment contents or paste a real key into a saved notebook.

## Documented connection options

Reviewed against the official documentation on **30 October 2026**. These URLs
are provider examples, not defaults the kit silently selects.

| Service | Provider base URL | Authentication / model selection | Official evidence |
|---|---|---|---|
| Claude | `https://api.anthropic.com/v1/` | Claude API key and an available Claude model ID. An unscoped personal/service key also needs `anthropic-workspace-id`; a workspace-scoped key does not. | [Anthropic compatibility](https://platform.claude.com/docs/en/cli-sdks-libraries/libraries/openai-sdk) |
| Ollama, local | `http://localhost:11434/v1/` | The local server ignores the placeholder key. Use an installed model ID from `ollama list`; cloud inference has separate authentication. | [Ollama compatibility](https://docs.ollama.com/api/openai-compatibility) |
| LM Studio | `http://localhost:1234/v1/` | Start its server and select a loaded chat model; use the actual configured port. Supply a token when server authentication is enabled. | [Compatibility endpoints](https://lmstudio.ai/docs/developer/openai-compat), [authentication](https://lmstudio.ai/docs/developer/core/authentication) |
| vLLM | Your server URL, commonly `http://localhost:8000/v1/` | Use a served chat-model name and the server key when authentication is configured. The server/model needs a suitable chat template. Running a vLLM server is separate from connecting this kit. | [vLLM online serving](https://docs.vllm.ai/en/latest/serving/online_serving/) |
| Gemini | `https://generativelanguage.googleapis.com/v1beta/openai/` | Gemini API key and an available Gemini model ID. Preserve the complete `/v1beta/openai/` prefix. | [Google compatibility](https://ai.google.dev/gemini-api/docs/openai) |

For an unscoped Claude key, the optional routing setting is:

```sh
export EXAKIT_PROVIDER_HEADERS='{"anthropic-workspace-id":"<workspace-id>"}'
```

This shared client does not implement native Anthropic Messages, Gemini-native
features, audio, vision, tool execution or provider-specific thinking controls.
Anthropic's compatibility layer ignores some unsupported parameters and does not
guarantee strict tool schemas. The kit asks for text; Ask separately validates
its JSON/SQL proposal and still requires approval. Endpoint compatibility alone
does not establish a model's SQL quality, runtime performance or account access.

## Configure a provider

For a local Ollama server, after installing/starting it and loading a chat model:

```sh
export EXAKIT_MODEL_ID="<exact-name-from-ollama-list>"
export EXAKIT_PROVIDER_BASE_URL="http://localhost:11434/v1/"
unset EXAKIT_PROVIDER_API_KEY EXAKIT_PROVIDER_HEADERS
exakit notebook
```

For another provider, set the same model/base-URL variables using the table and
supply its key securely in the process environment. On macOS zsh, this prompt
avoids putting the value in shell history:

```zsh
read -r -s "EXAKIT_PROVIDER_API_KEY?Provider API key: "
printf '\n'
export EXAKIT_PROVIDER_API_KEY
```

PowerShell uses the identical setting names:

```powershell
$env:EXAKIT_MODEL_ID = '<exact-model-id>'
$env:EXAKIT_PROVIDER_BASE_URL = '<provider-api-base-url>'
# Supply EXAKIT_PROVIDER_API_KEY securely when required by that provider.
exakit notebook
```

When switching providers, replace or clear both the key and optional headers.
Existing user notebook copies are preserved by updates: change their settings
to these names, or save a fresh copy of the current originals. In a notebook:

```python
import exakit.nb as nb
nb.model_settings()
```

The result contains the model ID, base URL, whether a key is configured and
header names. It omits key/header values and makes no network request. A
configured result is not an authentication or inference success check.

## Optional tracing

`LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY` and `LANGFUSE_BASE_URL` remain
separate: they select the tracing project, not the model. With tracing enabled,
the same configured provider client is instrumented by Langfuse; without it the
ordinary client is used. Explore still starts with `USE_AI_THEMES = False`.
Set it to `True` deliberately to send the selected descriptions to your model.

Local inference keeps model execution on the local server. Langfuse Cloud still
receives recorded inputs and outputs when Cloud tracing is enabled. Provider
token counts are recorded when returned; local/custom model costs may be absent.

## What has actually been verified

| Evidence | What it proves | What it does not prove |
|---|---|---|
| Official links above | Each service documents the shared text/chat protocol and its connection requirements | A live account, running server or every model works |
| `tests/test_model_provider.py` configuration tests | Explicit settings, keyless use, no ambient SDK-key fallback, redacted diagnostics, URL/header validation and shared profiling-note configuration | Remote authentication |
| Five local HTTP contracts, using the real SDK | The model/messages, base paths, fixture authentication, optional workspace header, response text and usage survive the client path for all five cases | Requests reached the actual Claude, Ollama, LM Studio, vLLM or Gemini service |
| Langfuse client-selection regression | The tracing client receives the same provider settings as the ordinary client | Real-provider tracing or Cloud/self-hosted version coverage |

The HTTP fixtures run only on loopback, with synthetic text and disposable dummy
credential values. No real provider key or paid inference is used. Run:

```sh
python3 tests/test_model_provider.py
```

Use the kit's notebook Python for the SDK/HTTP cases; without the SDK those cases
are explicitly skipped. CI also runs them in its Python 3.11 SDK environment. Live provider
acceptance requires a separately configured account/server, a successful text
response and inspection of its delivered trace. It remains unverified until run.


## Validate SQL drafting before relying on a model

`nb.ask(ds, question, table_description=..., request_timeout=30,
max_output_tokens=1024)` optionally supplies schema metadata and bounds one
request with retries disabled. It validates a JSON object (or one JSON fenced
block) with `sql` and string arrays `assumptions`/`doubts`. It still requires
`proposal.approve()` before executing the exact SQL through read-only MCP.
Provider chat compatibility does not guarantee SQL quality or support for every
sampling option; test the exact model/server combination.

Use `tools/ask_benchmark.py --help` and the acceptance guide to compare models.
The model receives the question, schema and required output column names;
it never receives reference SQL or result rows. Scores compare complete rows,
column positions and duplicate counts, ignoring row order and aliases. Results
at the MCP 1,000-row cap cannot count as correct. Each model request has a
configurable timeout and output-token bound. No paid provider was exercised by
the local compatibility contracts or Ollama acceptance checks.
