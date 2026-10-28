import marimo

__generated_with = "0.25.2"
app = marimo.App()

@app.cell
def _():
    import marimo as mo
    from exakit.nb.example_runtime import Lesson, render
    lesson = Lesson('gpu_in_udf/advanced_udf_with_gpu.ipynb')
    return lesson, mo, render

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    # Bundled Exasol lesson: Advanced Udf With Gpu

    Requires a GPU-capable Exasol host and GPU SLC. The local Mac kit does not provision these.

    Run cells from top to bottom. In Marimo each editable cell has its own Run button; opening a lesson executes no example code. Widget steps retain their Python code; use the matching Jupyter notebook for the original widget UI.

    For dashboards use the kit Data Scientist 03_share flow on Dash Server.

    Source: [Exasol Notebook Connector](https://github.com/exasol/notebook-connector/blob/14e2c7ad088b7109aa21d283e98f3126bbbe27e5/exasol/nb_connector/resources/notebooks/gpu_in_udf/advanced_udf_with_gpu.ipynb). MIT license: LICENSE.txt.
    """)
    return

@app.cell
def _(mo):
    editor_001 = mo.ui.code_editor(value="from exakit.nb.example_runtime import bootstrap\nai_lab_config = bootstrap(globals(), 'gpu_in_udf/advanced_udf_with_gpu.ipynb')", language="python", min_height=100)
    run_001 = mo.ui.run_button(label="Run cell 1")
    mo.vstack([editor_001, run_001])
    return editor_001, run_001

@app.cell
def _(editor_001, lesson, mo, render, run_001):
    mo.stop(not run_001.value)
    render(mo, lesson.run(editor_001.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    <div style="text-align: right;">
      <img src="https://raw.githubusercontent.com/exasol/ai-lab/refs/heads/main/assets/Exasol_Logo_2025_Dark.svg" style="width:200px; margin: 10px;" />
    </div>

    ## Advanced UDF using GPU Acceleration

    This perform an in-depth analysis of news articles using the data provided in the S3 virtual schema tutorial. The dataset that we will be working with, is derived from the well-known Reuters 21578 collection—a comprehensive repository of documents containing a wide variety of news articles, each categorized according to its subject matter.

    Our first step will be to create two distinct columns:
    1. Column **Topics:** will contain unique topics present in each news article, allowing us to systematically analyze the subject areas covered by the news article.
    2. Column **Titles:** will contain the headline or title of each news article, which we will later use for semantic matching.

    Once our tables are set up and populated, we will utilize a powerful natural language processing approach to link news article titles to their most relevant topics. Specifically, we will employ the `sentence-transformers` model—a state-of-the-art model designed for producing high-quality sentence embeddings. This model will run in a UDF leveraging the GPU to efficiently generate vector representations for both the titles and topics.

    By comparing these embeddings, our system will automatically match each article title with the most relevant topic from our topics table. Finally, we will output the top-N topics for each title, providing valuable insights into the subject distribution of our set of news articles.
    """)
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ### Open Secure Configuration Storage
    """)
    return

@app.cell
def _(mo):
    editor_002 = mo.ui.code_editor(value='print("Using the Starter Kit encrypted connection; tutorial schema: EXAKIT_EXAMPLES.")', language="python", min_height=100)
    run_002 = mo.ui.run_button(label="Run cell 2")
    mo.vstack([editor_002, run_002])
    return editor_002, run_002

@app.cell
def _(editor_002, lesson, mo, render, run_002):
    mo.stop(not run_002.value)
    render(mo, lesson.run(editor_002.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ### Prerequisites
    - Run the [S3 VS tutorial](/?file=exasol-examples/cloud/02_s3_vs_reuters.py) in order to populate the input data
    """)
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ### Instantiate ScriptLanguagesContainer

    The following cell creates an instance of class `ScriptLanguageContainer` from the notebook-connector,
    which enables us to use a custom Script Language Container (SLC)
    """)
    return

@app.cell
def _(mo):
    editor_003 = mo.ui.code_editor(value='from exasol.nb_connector.slc import ScriptLanguageContainer\nslc = ScriptLanguageContainer(secrets=ai_lab_config, name="gpu_slc")', language="python", min_height=100)
    run_003 = mo.ui.run_button(label="Run cell 3")
    mo.vstack([editor_003, run_003])
    return editor_003, run_003

@app.cell
def _(editor_003, lesson, mo, render, run_003):
    mo.stop(not run_003.value)
    render(mo, lesson.run(editor_003.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ### Connect to the Database and activate the Container
    """)
    return

@app.cell
def _(mo):
    editor_004 = mo.ui.code_editor(value='from exasol.nb_connector.language_container_activation import open_pyexasol_connection_with_lang_definitions\n\nconn = open_pyexasol_connection_with_lang_definitions(ai_lab_config, schema=ai_lab_config.db_schema, compression=True)', language="python", min_height=100)
    run_004 = mo.ui.run_button(label="Run cell 4")
    mo.vstack([editor_004, run_004])
    return editor_004, run_004

@app.cell
def _(editor_004, lesson, mo, render, run_004):
    mo.stop(not run_004.value)
    render(mo, lesson.run(editor_004.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ### Prepare the Models
    """)
    return

@app.cell
def _(mo):
    editor_005 = mo.ui.code_editor(value='from exasol.nb_connector.model_installation import install_model, TransformerModel\nfrom transformers import AutoModel', language="python", min_height=100)
    run_005 = mo.ui.run_button(label="Run cell 5")
    mo.vstack([editor_005, run_005])
    return editor_005, run_005

@app.cell
def _(editor_005, lesson, mo, render, run_005):
    mo.stop(not run_005.value)
    render(mo, lesson.run(editor_005.value))
    return

@app.cell
def _(mo):
    editor_006 = mo.ui.code_editor(value='install_model(ai_lab_config, TransformerModel(\n                "sentence-transformers/all-mpnet-base-v2", "feature-extraction", AutoModel\n            ),)', language="python", min_height=100)
    run_006 = mo.ui.run_button(label="Run cell 6")
    mo.vstack([editor_006, run_006])
    return editor_006, run_006

@app.cell
def _(editor_006, lesson, mo, render, run_006):
    mo.stop(not run_006.value)
    render(mo, lesson.run(editor_006.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ### Create the UDF

    Now we are ready to create the UDF implementing the "semantic join" between pairs of text data (_text1_, _text2_) by computing their semantic similarity using a transformer neural network model (from the sentence-transformers library). It runs on a GPU and is designed to scale to large amounts of data by processing in batches. For each pair (_text1_, _text2_), it computes the cosine similarity between their embeddings on the GPU. The UDF returns (emits) _text1_ and _text2_, as well as the `similarity_score` (between -1 and 1, with 1.0 = identical).
    """)
    return

@app.cell
def _(mo):
    editor_007 = mo.ui.code_editor(value='sql_semantic_join = f"""\n--/\nCREATE OR REPLACE {slc.language_alias} SET SCRIPT "SEMANTIC_JOIN"(text1 VARCHAR(2000000), text2 VARCHAR(2000000))\nEMITS(text1 VARCHAR(2000000), text2 VARCHAR(2000000), similarity_score DOUBLE) AS\n%perInstanceRequiredAcceleratorDevices GpuNvidia;\n\nimport pandas as pd\nfrom transformers import AutoTokenizer, AutoModel, Pipeline, pipeline\nimport torch\nimport exasol.bucketfs as bfs\nfrom pathlib import Path\nfrom exasol_transformers_extension.utils import device_management\nfrom exasol.python_extension_common.connections.bucketfs_location import (\n    create_bucketfs_location_from_conn_object)\nfrom exasol_transformers_extension.utils.bucketfs_model_specification import (\n    BucketFSModelSpecification)\nfrom exasol_transformers_extension.utils.huggingface_hub_bucketfs_model_transfer_sp import (\n    HuggingFaceHubBucketFSModelTransferSP)\nfrom exasol_transformers_extension.utils.load_local_model import LoadLocalModel\n\n\ndevice = torch.device("cuda")\n\ndef get_bucketfs_location(exa, bucketfs_conn_name: str) -> bfs.path.PathLike:\n    return create_bucketfs_location_from_conn_object(\n        exa.get_connection(bucketfs_conn_name))\n\ndef load_transformers_pipline(exa,\n                              bucketfs_conn_name: str,\n                              sub_dir: str,\n                              device: str,\n                              task_type: str,\n                              model_name: str,\n                              model_factory,\n                              tokenizer_factory=AutoTokenizer) -> Pipeline:\n    model_loader = LoadLocalModel(pipeline,\n                                  base_model_factory=model_factory,\n                                  tokenizer_factory=tokenizer_factory,  # type: ignore\n                                  task_type=task_type,\n                                  device=device)    # type: ignore\n\n    model_spec = BucketFSModelSpecification(model_name, task_type, bucketfs_conn_name,\n                                            Path(sub_dir))\n\n    bucketfs_location = get_bucketfs_location(exa, bucketfs_conn_name)\n\n    model_loader.clear_device_memory()\n    model_loader.set_current_model_specification(model_spec)\n    model_loader.set_bucketfs_model_cache_dir(bucketfs_location)\n    return model_loader.load_models()\n\nmodel_pipeline = load_transformers_pipline(\n    exa,\n    bucketfs_conn_name=\'{ai_lab_config.bfs_connection_name}\',\n    sub_dir=\'{ai_lab_config.bfs_model_subdir}\',\n    device=device,\n    model_name="sentence-transformers/all-mpnet-base-v2",\n    task_type=\'feature-extraction\',\n    model_factory=AutoModel)\n\n# Function to calculate embeddings\ndef batch_get_embeddings(batch_texts, model_pipeline, device):\n    # Tokenize the batch of texts\n    inputs = model_pipeline.tokenizer(batch_texts, padding=True, truncation=True, return_tensors=\'pt\').to(device)  # Send to GPU\n    # Get embeddings from the model\n    with torch.no_grad():\n        outputs = model_pipeline.model(**inputs)\n    # Use the outputs pooler_output or last_hidden_state to get the embedding\n    return outputs.pooler_output if \'pooler_output\' in outputs else outputs.last_hidden_state.mean(dim=1)\n\n# Function to compute row-by-row cosine similarity using PyTorch\ndef row_by_row_cosine_similarity_gpu(embeddings1, embeddings2):\n    # Normalized embeddings can be calculated separately\n    normalized_embeddings1 = embeddings1 / embeddings1.norm(dim=1)[:, None]\n    normalized_embeddings2 = embeddings2 / embeddings2.norm(dim=1)[:, None]\n\n    # Compute pair-wise cosine similarity for each corresponding pair\n    similarities = (normalized_embeddings1 * normalized_embeddings2).sum(dim=1)\n    return similarities\n\ndef run(ctx):\n    # Batch processing configurations\n    batch_size = 100  # Adjust this based on your memory capacity\n\n    while True:\n        df = ctx.get_dataframe(batch_size)\n        if df is None:\n            break\n\n        data1 = df["text1"]\n        data2 = df["text2"]\n\n        # Compute embeddings for each dataset in batches\n        embeddings1 = batch_get_embeddings(data1.to_list(), model_pipeline, device)\n        embeddings2 = batch_get_embeddings(data2.to_list(), model_pipeline, device)\n\n        # Calculate row-by-row cosine similarity using PyTorch on GPU\n        similarity_scores = row_by_row_cosine_similarity_gpu(embeddings1, embeddings2)\n\n        # Determine matches based on similarity scores (threshold can be adjusted)\n        df["SIMILARITY_SCORE"]=similarity_scores.cpu()\n        ctx.emit(df)\n/\n"""\nconn.execute(sql_semantic_join)', language="python", min_height=100)
    run_007 = mo.ui.run_button(label="Run cell 7")
    mo.vstack([editor_007, run_007])
    return editor_007, run_007

@app.cell
def _(editor_007, lesson, mo, render, run_007):
    mo.stop(not run_007.value)
    render(mo, lesson.run(editor_007.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ### Initialize JupySQL
    Let's bring up JupySQL and connect to the database via SQLAlchemy. Please refer to the documentation of <a href="https://github.com/exasol/sqlalchemy-exasol" target="_blank" rel="noopener">sqlalchemy-exasol</a> for details on how to connect to the database using the Exasol SQLAlchemy driver.
    """)
    return

@app.cell
def _(mo):
    editor_008 = mo.ui.code_editor(value='from exakit.nb.example_runtime import init_sql as jupysql_init\njupysql_init(ai_lab_config)', language="python", min_height=100)
    run_008 = mo.ui.run_button(label="Run cell 8")
    mo.vstack([editor_008, run_008])
    return editor_008, run_008

@app.cell
def _(editor_008, lesson, mo, render, run_008):
    mo.stop(not run_008.value)
    render(mo, lesson.run(editor_008.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ### Run the UDF on the New Data

    Now we apply the `semantic_join` UDF on the topics and titles from the NEWS table, which was created by the S3 Virtual Schema tutorial. The query will return for every news TITLE, the TOPICs that best semantically match it, ranks them by how similar they are, and filters out all but the strong matches (similarity > 0.5). You get, for each TITLE, a list of most plausible TOPICs, in order.
    """)
    return

@app.cell
def _(mo):
    editor_009 = mo.ui.code_editor(value='%%sql\nSELECT *\nFROM (\n    SELECT\n        TEXT1 AS TITLE, TEXT2 AS TOPIC,\n        RANK() OVER (PARTITION BY TEXT1 ORDER BY SIMILARITY_SCORE DESC) as r,\n        SIMILARITY_SCORE\n    FROM (\n        SELECT\n            "SEMANTIC_JOIN"(TITLE, TOPIC)\n        FROM (\n            SELECT distinct TOPIC, TITLE\n            FROM (\n                SELECT distinct title as TITLE FROM NEWS WHERE TITLE IS NOT NULL AND BODY IS NOT NULL\n            )\n            CROSS JOIN (\n                SELECT distinct topic AS TOPIC FROM NEWS WHERE topic IS NOT NULL\n            )\n        )\n    )\n    WHERE SIMILARITY_SCORE > 0.5\n)\nWHERE r<=5\nORDER BY TITLE, r ASC', language="python", min_height=100)
    run_009 = mo.ui.run_button(label="Run cell 9")
    mo.vstack([editor_009, run_009])
    return editor_009, run_009

@app.cell
def _(editor_009, lesson, mo, render, run_009):
    mo.stop(not run_009.value)
    render(mo, lesson.run(editor_009.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ### Additional Notes

    #### Parallel execution
    Please note that executing multiple queries with GPU UDFs in parallel can lead to unexpected errors, as the GPU libraries used within the UDFs may attempt to allocate the same GPU device and memory simultaneously. In the current Exasol version, the user responsible to ensure that the libraries are configured appropriately or that only one query uses a GPU device.

    Check out the [GPU Resource Considerations](/?file=exasol-examples/gpu_in_udf/gpu_resource_considerations.py) model for more information.
    """)
    return

if __name__ == "__main__":
    app.run()
