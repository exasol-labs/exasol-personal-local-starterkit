# Connect a text model and trace its calls

The same three names configure Explore, optional Ask SQL drafting and optional
column notes. The kit supplies a client for **text Chat Completions**. You choose
the server and a model it actually serves; model weights are not bundled.

| Setting | Meaning |
|---|---|
| `EXAKIT_MODEL_ID` | Exact model identifier accepted by your provider/server |
| `EXAKIT_PROVIDER_BASE_URL` | API base URL, including its version/prefix; not a full request URL. With an API key it must be `https://`, unless the server is on this machine or your own network (a loopback, private or link-local address, a `.local` name): a key is never sent in clear text across networks. The same rule keeps tracing off for a plain-`http://` `LANGFUSE_BASE_URL` elsewhere |
| `EXAKIT_PROVIDER_API_KEY` | Provider credential; leave unset only if that server allows unauthenticated calls |
| `EXAKIT_PROVIDER_HEADERS` | Optional JSON map of additional routing headers; omit unless required |
| `EXAKIT_MODEL_TEMPERATURE` | Optional, 0 to 2. Unset (the default) sends no temperature: Claude Opus 4.7 and later refuse one with HTTP 400. Set `0` for a local model that should answer the same way twice |

No model ID means optional AI stays disabled. A selected model requires an
explicit base URL. Blank keys use a non-secret SDK placeholder for unauthenticated
servers. Embedded URL credentials, query/fragment parameters and full request
paths such as `/chat/completions` are refused. Authentication belongs in the key
setting, not custom `Authorization`, `api-key` or `x-api-key` headers.

Every call passes the selected base URL and key explicitly to the SDK. Unrelated
SDK environment credentials do not supply either value. Settings are read on
each call; a new terminal's environment does not reach an already-running server.
*Set them once* below says how to set them, and the *Your AI model and Langfuse* cell
in Explore and Ask sets them in one kernel instead. Do not print environment contents
or paste a real key into a saved notebook.

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

## Set them once, before `exakit notebook`

The notebook server takes its environment from the terminal that starts it, and the
kernels take theirs from the server. So: set everything in one terminal, start the
notebooks from that terminal, and every notebook has the model and Langfuse without
touching the *Your AI model and Langfuse* cell. Each key is typed into a hidden
prompt: it is never part of a command, so it is not in the shell's history either.

Mac and Linux (bash or zsh), for Claude:

```sh
export EXAKIT_MODEL_ID="claude-opus-5-5"
export EXAKIT_PROVIDER_BASE_URL="https://api.anthropic.com/v1/"
printf 'Model API key: '; read -rs EXAKIT_PROVIDER_API_KEY; echo; export EXAKIT_PROVIDER_API_KEY

export LANGFUSE_BASE_URL="https://cloud.langfuse.com"      # or your own Langfuse's https:// address
printf 'Langfuse public key: '; read -rs LANGFUSE_PUBLIC_KEY; echo; export LANGFUSE_PUBLIC_KEY
printf 'Langfuse secret key: '; read -rs LANGFUSE_SECRET_KEY; echo; export LANGFUSE_SECRET_KEY

exakit notebook
```

Windows PowerShell (5.1 or later), the same names:

```powershell
$env:EXAKIT_MODEL_ID = "claude-opus-5-5"
$env:EXAKIT_PROVIDER_BASE_URL = "https://api.anthropic.com/v1/"
$env:EXAKIT_PROVIDER_API_KEY = [Net.NetworkCredential]::new("", (Read-Host "Model API key" -AsSecureString)).Password

$env:LANGFUSE_BASE_URL = "https://cloud.langfuse.com"
$env:LANGFUSE_PUBLIC_KEY = [Net.NetworkCredential]::new("", (Read-Host "Langfuse public key" -AsSecureString)).Password
$env:LANGFUSE_SECRET_KEY = [Net.NetworkCredential]::new("", (Read-Host "Langfuse secret key" -AsSecureString)).Password

exakit notebook
```

A local Ollama server needs no key and no Langfuse; after loading a chat model:

```sh
export EXAKIT_MODEL_ID="<exact-name-from-ollama-list>"
export EXAKIT_PROVIDER_BASE_URL="http://localhost:11434/v1/"
unset EXAKIT_PROVIDER_API_KEY EXAKIT_PROVIDER_HEADERS
exakit notebook
```

Three rules:

- **Already running?** The server read its environment when it started, and a kernel
  restart does not re-read it. Run `exakit notebook stop`, then `exakit notebook`, in the
  terminal that has the variables. Marimo: `exakit notebook marimo`, the same way.
- **The plain values can live in the settings file.** `~/.exasol-starter-kit/exakit.env`
  has an `EXAKIT_MODEL_ID` and an `EXAKIT_PROVIDER_BASE_URL` line (and
  `EXAKIT_PROVIDER_HEADERS`, `EXAKIT_MODEL_TEMPERATURE`): remove the `# ` and set them once,
  and every `exakit` command, the notebook server included, sees them. The file refuses a
  key (`*API_KEY*`, `*SECRET*`, `*TOKEN*`), and it reads `EXAKIT_*` names only, so the
  Langfuse address and all three keys stay in the terminal as above.
- **Leave them out and nothing breaks.** No `EXAKIT_MODEL_ID` means the AI steps skip and
  say so; no Langfuse variables means tracing is off. Set only what you use.

Skip a value in the hidden prompt with Enter: an empty key is the same as none.

In a notebook, `nb.model_setup()` prints this page's essentials for the machine it runs on
(Windows, Mac, Linux or WSL): the six names with set / not set, the `nb.use_model(...)` way,
the terminal lines, the restart rule and the settings file. The install's closing screen
shows the same lines when the notebook add-on is installed.

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
separate: they select the tracing project, not the model. *Set them once* above shows
the three lines that set them, keys in a hidden prompt. With tracing enabled,
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

Use `tools/ask_benchmark.py --help` to compare models.
The model receives the question, schema and required output column names;
it never receives reference SQL or result rows. Scores compare complete rows,
column positions and duplicate counts, ignoring row order and aliases. Results
at the MCP 1,000-row cap cannot count as correct. Each model request has a
configurable timeout and output-token bound. No paid provider was exercised by
the local compatibility contracts or Ollama acceptance checks.
