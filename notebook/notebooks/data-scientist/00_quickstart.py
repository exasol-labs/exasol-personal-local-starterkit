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
# **Start here · Your kit and your data.** Click into the cell below and press **Shift + Enter** to open it: the kit's state, then your data and its column map. Its **Guided / Code** switch, top right, shows the code behind this page.
#
# </div>

# %% tags=["exakit-guide", "skip-ci"]
# Your kit and your data: the guided view of this page. Guided / Code, top right, switches to the code cells below.
import exakit.guide as guide

guide.start()

# %% [markdown] tags=["exakit-code-start"]
# # The code behind this page
#
# <div class="guide-code-start"></div>
#
# The same steps as the cards above, as cells you can read, change and run one by one. **Code**, at the top right of a card, opens this section; **Guided** closes it again.

# %% [markdown]
# ## Start here: access and understand your data
#
# **Dataset:** `amazon_sales` (default), `fraud_transactions` or your own file.
#
# ![Steps 0 Check the kit, 1 Access and 2 Understand. All steps: Access, Understand, Prepare, Explore, Model, Validate, Ask with AI, Share, Hand off](journey:0,1,2)
#
# At the end you have a connection, an approved column map and a first result. No AI model is needed. Kit commands run from these cells, so you do not need a terminal.

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
# What the kit has, read live: the same calls the Home card shows.
components = nb.components()            # the kit's parts, their versions and pending updates
addons = nb.addons()                    # the marketplace's add-ons and their state
ai_clients = nb.ai_clients()            # the AI clients the kit can connect, and which are connected
sample_datasets = nb.sample_datasets()  # the kit's sample datasets, and which are loaded
loaded_files = nb.loaded_files()        # the files you loaded with exakit data-load: table, rows, file
notebooks = nb.notebooks("data-scientist")   # this persona's notebooks, in order
persona_plan = nb.persona_plan()        # what this kit's personas bring that is still missing
approved = nb.approved_datasets()       # the column maps approved so far
workflows = nb.list_workflows()         # every workflow log; the last one's events:
workflow_events = nb.workflow_log(workflows[-1]["id"]) if workflows else []
model, tracing = nb.model_settings(), nb.tracing()
[(c["id"], c["installed"], c["status"]) for c in components]

# %%
# Change the kit from here: set what you want, run the cell; each runs as `exakit` would, its log in the cell.
START_DATABASE = False   # start the database after a restart of this computer
ADD_ON = ""              # an add-on to install and start, e.g. one of [a["id"] for a in addons]
LOAD = ""                # a kit dataset (sample_datasets), a file or a folder, loaded with exakit data-load
LOAD_SCHEMA = ""         # where a file or folder lands (empty: STARTER_KIT, exakit's default)
SERVICE = ""             # a service to start (kit_state["services"]), then its log
CHECK_AI = False         # check the AI clients' connection to the database (mcp-doctor)
UPDATE_KIT = False       # bring the kit and its add-ons up to date
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

# %%
# Your AI model and Langfuse tracing, remembered for every notebook of this kit (readable by you only). The keys are
# asked in a hidden box. Empty values change nothing; FORGET deletes what was remembered. The Home card's AI model
# row does the same with menus: pick the provider, give the key, pick the model and its effort.
providers = {p["id"]: p for p in nb.model_providers()}   # the providers the kit knows, with their addresses
PROVIDER = ""            # one of providers, e.g. "anthropic", "openai", "gemini", "ollama"
SHOW_MODELS = False      # True: list the models your key may use (the key is asked in a hidden box)
MODEL_ID = ""            # one of those models
EFFORT = ""              # where the model takes one (nb.effort_levels(PROVIDER, MODEL_ID)): "low", "medium", "high"
PROVIDER_BASE_URL = ""   # empty: the provider's own address; or any Chat Completions address of your own
LANGFUSE_BASE_URL = ""   # e.g. "https://cloud.langfuse.com"
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
# ## Step 2 · Understand the data
#
# You approve the column map: the key, the date, the groups and the outcome. The kit proposes it and shows the least certain columns first. Every later step reads this map, so the same notebooks run on any table.

# %% [include] ../00_shared/data_paths.py review

# %% [markdown]
# ### A first result
#
# Rows per group, and the % where the target is 1 when the map has a target. Each query shows its SQL before the result.

# %%
missing_roles = {missing["role"]: missing["reason"] for missing in dataset.missing}
GROUP_ROLE, GROUP_COLUMN = dataset.group_by()   # the category, else the entity, else the target
if GROUP_ROLE != "category":
    print(f"No category ({missing_roles.get('category', 'none approved')}): rows are counted per {GROUP_ROLE} instead.")
if "label" in missing_roles:
    print(f"No target ({missing_roles['label']}): the target rate is left out. Later steps that need it say so.")
GROUP_HEADER, COUNT_HEADER = nb.name(GROUP_COLUMN), nb.count_name(dataset)       # columns named after the data: CATEGORY, ORDER_LINES
LABEL_PCT_HEADER = nb.name(dataset.col("label"), "PCT") if dataset.has("label") and GROUP_ROLE != "label" else None   # CANCELLED_PCT
LABEL_RATE_SQL = f",\n       ROUND(100 * AVG({dataset.col('label')}), 1) AS {LABEL_PCT_HEADER}" if LABEL_PCT_HEADER else ""
first_rows = nb.sql(connection, f"""
SELECT {GROUP_COLUMN} AS {GROUP_HEADER},
       COUNT(*) AS {COUNT_HEADER}{LABEL_RATE_SQL}
FROM {dataset.fact_table}
GROUP BY {GROUP_COLUMN}
ORDER BY {COUNT_HEADER} DESC
LIMIT 10""")
nb.show_sql()
overall_rate = nb.sql(connection, f"SELECT COUNT(*) AS N, ROUND(100 * AVG({dataset.col('label')}), 1) AS PCT FROM {dataset.fact_table}") if LABEL_PCT_HEADER else None
nb.note_groups(first_rows, dataset, GROUP_HEADER, COUNT_HEADER, LABEL_PCT_HEADER, overall=(overall_rate["N"][0], overall_rate["PCT"][0]) if LABEL_PCT_HEADER else None)
first_rows

# %% [markdown]
# ## Next
#
# Open `01_explore` to prepare, explore, model and validate (steps 3 to 6). Then open `02_ask_your_data` (step 7) and `03_share` (steps 8 and 9). Each one continues this workflow.

