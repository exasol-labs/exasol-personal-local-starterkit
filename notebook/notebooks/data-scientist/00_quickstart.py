# ---
# jupyter:
#   kernelspec:
#     display_name: Exasol (Starter Kit)
#     language: python
#     name: exasol-starter-kit
# ---

# %% [markdown] tags=["exakit-guide-hint"]
# <div class="guide-start-hint">
#
# **Start here · Your kit and your data.** Click into the cell below and press **Shift + Enter** to open it: the kit's state, then your data: datasets, your own files and tables, and external sources. Its **Guided / Code** switch, top right, shows the code behind this page.
#
# </div>

# %% tags=["exakit-guide", "skip-ci"]
import exakit.guide as guide

guide.start()

# %% [markdown] tags=["exakit-code-start"]
# # The code behind this page
#
# <div class="guide-code-start"></div>
#
# The same steps as the cards above, as cells you can read, change and run one by one. **Code**, at the top right of a card, opens this section; **Guided** closes it again.

# %% [markdown]
# ## Start here: your kit and your data
#
# **Dataset:** `amazon_sales` (default), `fraud_transactions` or your own file.
#
# ![Steps 0 Check the kit and 1 Access. All steps: Access, Understand, Prepare, Explore, Model, Validate, Ask with AI, Share, Hand off](journey:0,1)
#
# At the end you have a connection and your data, from as many sources as you like. `01_explore` opens it to understand it: the column map and the semantic views. No AI model is needed. Kit commands run from these cells, so you do not need a terminal.

# %% [markdown]
# ## Step 0 · Check the kit
#
# Shows what is installed and running: the database, each add-on and the loaded datasets. It changes nothing.
#
# The next cells read the rest of the kit live, change it from here (each with its log in the cell), and set up your AI model and Langfuse tracing. They are the calls the Home card's rows and buttons make.

# %%
import exakit.nb as nb

kit_state = nb.kit_check()

# %%
components = nb.components()
addons = nb.addons()
ai_clients = nb.ai_clients()
sample_datasets = nb.sample_datasets()
loaded_files = nb.loaded_files()
sources = nb.sources()
notebooks = nb.notebooks("data-scientist")
persona_plan = nb.persona_plan()
approved = nb.approved_datasets()
workflows = nb.list_workflows()
workflow_events = nb.workflow_log(workflows[-1]["id"]) if workflows else []
model, tracing = nb.model_settings(), nb.tracing()
[(c["id"], c["installed"], c["status"]) for c in components]

# %% [markdown]
# | Setting | What it does |
# |---|---|
# | `START_DATABASE` | start the database after a restart of this computer |
# | `ADD_ON` | an add-on to install and start: one of `[a["id"] for a in addons]` |
# | `LOAD`, `LOAD_SCHEMA` | a kit dataset, a file or a folder to load, and the schema it lands in |
# | `SERVICE` | a service to start, then its log |
# | `CHECK_AI` | check the AI clients' connection to the database |
# | `UPDATE_KIT` | bring the kit and its add-ons up to date |

# %%
START_DATABASE = False
ADD_ON = ""
LOAD = ""
LOAD_SCHEMA = ""
SERVICE = ""
CHECK_AI = False
UPDATE_KIT = False
if START_DATABASE:
    nb.exakit("start")
if ADD_ON:
    nb.addon_ready(ADD_ON)
if LOAD:
    nb.exakit("data-load", LOAD, env={"EXAKIT_SCHEMA": LOAD_SCHEMA.upper()} if LOAD_SCHEMA else None)
if SERVICE:
    nb.exakit("start", SERVICE)
    nb.exakit("logs", SERVICE)
if CHECK_AI:
    nb.exakit("mcp-doctor")
if UPDATE_KIT:
    nb.kit_update()

# %% [markdown]
# | Setting | What it does |
# |---|---|
# | `PROVIDER` | one of `providers`: `"anthropic"`, `"openai"`, `"gemini"`, `"ollama"` |
# | `SHOW_MODELS` | list the models your key may use; the key is asked in a hidden box |
# | `MODEL_ID`, `EFFORT` | the model, and its effort where it takes one |
# | `PROVIDER_BASE_URL` | empty: the provider's own address |
# | `LANGFUSE_BASE_URL` | where model calls are traced, such as `https://cloud.langfuse.com` |
# | `FORGET` | delete what was remembered |

# %%
providers = {p["id"]: p for p in nb.model_providers()}
PROVIDER = ""
SHOW_MODELS = False
MODEL_ID = ""
EFFORT = ""
PROVIDER_BASE_URL = ""
LANGFUSE_BASE_URL = ""
FORGET = False
if PROVIDER and not PROVIDER_BASE_URL:
    PROVIDER_BASE_URL = providers[PROVIDER]["base_url"]
if PROVIDER and SHOW_MODELS:
    print(nb.provider_models(PROVIDER, base_url=PROVIDER_BASE_URL))
if MODEL_ID:
    nb.use_model(MODEL_ID, PROVIDER_BASE_URL, effort=EFFORT, remember=True)
if LANGFUSE_BASE_URL:
    nb.use_model(langfuse_base_url=LANGFUSE_BASE_URL, remember=True)
if FORGET:
    nb.forget_model(model=True, langfuse=True)

# %% [markdown]
# ## Step 1 · Access the data
#
# Starts a workflow, connects to the database and loads a dataset: a practice dataset, your own file or a connected source.

# %% [markdown]
# ### Start a workflow
#
# The workflow gives one ID to every query and decision below. The next notebooks continue it. You do not copy anything.

# %%
import os
import exakit.nb as nb

workflow_id = nb.workflow("data-scientist-quickstart", resume=os.environ.get("EXAKIT_WORKFLOW_ID"))
print(f"Workflow {workflow_id}: every step below is recorded under it.")

# %% [include] ../00_shared/data_paths.py connect

# %% [include] ../00_shared/data_paths.py load

# %% [markdown]
# ### Carry the choice to the next notebook
#
# `01_explore` opens the tables chosen here: their column maps and semantic views are its first step. Several tables? Put them all in: `nb.remember_chosen(chosen_tables)`.

# %% [markdown]
# `OPEN_APPROVED`: a dataset approved before, by its id (`nb.approved_datasets()` lists them).

# %%
OPEN_APPROVED = ""
if OPEN_APPROVED:
    chosen_data = nb.dataset(connection, OPEN_APPROVED)
remembered = nb.remember_chosen(chosen_data)
print("01_explore opens: " + ", ".join(remembered))

# %% [markdown]
# ## Next
#
# Open `01_explore` to understand your data - the column map and the semantic views - then prepare, explore, model and validate (steps 2 to 6). Then open `02_ask_your_data` (step 7) and `03_share` (steps 8 and 9). Each one continues this workflow.

