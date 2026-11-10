import marimo

__generated_with = "0.25.2"
app = marimo.App()

@app.cell
def _():
    import marimo as mo
    from exakit.nb.example_runtime import Lesson, render
    lesson = Lesson('gpu_in_udf/gpu_resource_considerations.ipynb')
    return lesson, mo, render

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    # Bundled Exasol lesson: GPU Resource Considerations

    Requires a GPU-capable Exasol host and GPU SLC. The local Mac kit does not provision these.

    Run cells from top to bottom. In Marimo each editable cell has its own Run button; opening a lesson executes no example code. Widget steps retain their Python code; use the matching Jupyter notebook for the original widget UI.

    For dashboards use the kit Data Scientist 03_share flow on Dash Server.

    Source: [Exasol Notebook Connector](https://github.com/exasol/notebook-connector/blob/14e2c7ad088b7109aa21d283e98f3126bbbe27e5/exasol/nb_connector/resources/notebooks/gpu_in_udf/gpu_resource_considerations.ipynb). MIT license: LICENSE.txt.
    """)
    return

@app.cell
def _(mo):
    editor_001 = mo.ui.code_editor(value="from exakit.nb.example_runtime import bootstrap\nai_lab_config = bootstrap(globals(), 'gpu_in_udf/gpu_resource_considerations.ipynb')", language="python", min_height=100)
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

    # GPU Resource Considerations

    In this tutorial we will learn about how to manage access to GPUs from UDFs.
    """)
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ## Open Secure Configuration Storage
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
    - Run the [Tutorial on the Virtual Schema for S3](/?file=exasol-examples/cloud/02_s3_vs_reuters.py) for populating the input data
    - Run the [Advanced UDF with GPU Support](/?file=exasol-examples/gpu_in_udf/advanced_udf_with_gpu.py) for initializing the AI models
    """)
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ### Instantiate ScriptLanguagesContainer

    The following cell creates an instance of `ScriptLanguageContainer` for managing Script Language Containers (SLCs).
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
    ### Import Python Modules
    """)
    return

@app.cell
def _(mo):
    editor_004 = mo.ui.code_editor(value='from exakit.nb.example_runtime import open_pyexasol_connection\nfrom exasol.nb_connector.language_container_activation import open_pyexasol_connection_with_lang_definitions\nimport textwrap\nimport pandas as pd', language="python", min_height=100)
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
    ### Check Database Compatibility

    This notebook works only correct on an Exasol Database version 2025.2.0 or later.
    """)
    return

@app.cell
def _(mo):
    editor_005 = mo.ui.code_editor(value='from packaging.version import Version\nfrom exasol.nb_connector.ui.common import popup_message\nwith open_pyexasol_connection(ai_lab_config, compression=True, schema=ai_lab_config.db_schema) as conn:\n    res = conn.execute("SELECT PARAM_VALUE FROM EXA_METADATA WHERE PARAM_NAME=\'databaseProductVersion\';").fetchall();\ndbVersion = Version(res[0][0])\nif dbVersion < Version("2025.2.0"):\n    popup_message.display_popup(f"This tutorial will not work correctly with the used database: The used queries here will not show the correct result.")', language="python", min_height=100)
    run_005 = mo.ui.run_button(label="Run cell 5")
    mo.vstack([editor_005, run_005])
    return editor_005, run_005

@app.cell
def _(editor_005, lesson, mo, render, run_005):
    mo.stop(not run_005.value)
    render(mo, lesson.run(editor_005.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ### How GPU Resources are Managed

    In each select/sub-select statement, only a single UDF call is allowed to exclusively use all the available GPUs. The resources are allocated by the GPU Resource Management individually for each UDF call.

    When several queries, each featuring a single GPU-accelerated user-defined function (UDF), are executed simultaneously, their executions are serialized. Each UDF call must await its turn, pausing until the exclusive use of accelerator resources becomes available. Only when resources are freed by preceding UDF calls can subsequent UDF executions proceed.

    This implies that it is not feasible to execute multiple GPU-accelerated UDF calls concurrently within a single select or sub-select statement. In such scenarios, only one UDF call will be executed as intended, while any additional calls will either fail or revert to CPU processing, depending upon the UDF configuration.

    To simulate two simultaneous SQL queries, we create first a long running UDF:
    """)
    return

@app.cell
def _(mo):
    editor_006 = mo.ui.code_editor(value='sql = f"""\nCREATE OR REPLACE {slc.language_alias} SCALAR SCRIPT\nlong_running_gpu(id INTEGER)\nEMITS (ID INT, START_TIME VARCHAR(1000), END_TIME VARCHAR(1000), NVIDIA_VISIBLE_DEVICES VARCHAR(10000)) AS\n %perInstanceRequiredAcceleratorDevices GpuNvidia|None;\n\nimport time\n\ndef timestamp():\n    now = datetime.datetime.now().time()\n    return str(now)\n    \ndef run(ctx):\n    start_timestamp = timestamp() \n    time.sleep(5)\n    nvidia_vis_devices = os.getenv(\'NVIDIA_VISIBLE_DEVICES\', "<invalid>")\n    end_timestamp = timestamp()\n    ctx.emit(ctx.id, start_timestamp, end_timestamp,  nvidia_vis_devices)\n/\n"""\n\nwith open_pyexasol_connection_with_lang_definitions(ai_lab_config, compression=True, schema=ai_lab_config.db_schema) as connection:\n    connection.execute(sql)', language="python", min_height=100)
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
    Now we execute this UDF in 2 different pyexasol connections, which run in parallel:
    """)
    return

@app.cell
def _(mo):
    editor_007 = mo.ui.code_editor(value='import multiprocessing\n\ndef run_long_running_udf(id):\n    with open_pyexasol_connection_with_lang_definitions(ai_lab_config, schema=ai_lab_config.db_schema, compression=True) as local_conn:\n        sql = f"SELECT long_running_gpu({id});"\n        result = local_conn.execute(sql)\n        df = pd.DataFrame(result.fetchall(), columns=result.column_names())\n        return df\n\nwith multiprocessing.Pool(processes=2) as pool:\n    results = pool.map(run_long_running_udf, [1, 2])\n\nres = pd.concat(results, ignore_index=True)\nres.sort_values(by=\'START_TIME\')', language="python", min_height=100)
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
    As you can see in the result above, the UDFs were executed sequentially.
    """)
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ### Multiple GPU-Accelerated UDF Calls in Single Query 

    Using more than one GPU-accelerated UDF call in a single query, will either raise an error or fall back to CPU usage.

    Let us define a UDF which requires a GPU and then use the UDF twice in the same query.
    """)
    return

@app.cell
def _(mo):
    editor_008 = mo.ui.code_editor(value='sql = textwrap.dedent(f"""\nCREATE OR REPLACE {slc.language_alias} SCALAR SCRIPT\ngpu_required()\nRETURNS VARCHAR(10000) AS\n %perInstanceRequiredAcceleratorDevices GpuNvidia;\n\ndef run(ctx):\n    return os.getenv(\'NVIDIA_VISIBLE_DEVICES\', "<invalid>")\n/\n""")\nwith open_pyexasol_connection_with_lang_definitions(ai_lab_config, schema=ai_lab_config.db_schema, compression=True) as conn:\n    conn.execute(sql)\n\ntry:\n    with open_pyexasol_connection_with_lang_definitions(ai_lab_config, schema=ai_lab_config.db_schema, compression=True) as conn:\n        stmt = conn.execute("SELECT gpu_required(), gpu_required();")\nexcept Exception as e:\n    print(e)', language="python", min_height=100)
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
    The same effect can happen with UDF (1) _requiring_ a GPU, and UDF (2) with optional CPU fallback, as the execution order cannot be predicted.
    """)
    return

@app.cell
def _(mo):
    editor_009 = mo.ui.code_editor(value='sql = textwrap.dedent(f"""\nCREATE OR REPLACE {slc.language_alias} SCALAR SCRIPT\ngpu_optional()\nRETURNS VARCHAR(10000) AS\n %perInstanceRequiredAcceleratorDevices GpuNvidia|None;\n\ndef run(ctx):\n    return os.getenv(\'NVIDIA_VISIBLE_DEVICES\', "<invalid>")\n/\n""")\n\nwith open_pyexasol_connection_with_lang_definitions(ai_lab_config, schema=ai_lab_config.db_schema, compression=True) as conn:\n    conn.execute(sql)\n\ntry:\n    with open_pyexasol_connection_with_lang_definitions(ai_lab_config, schema=ai_lab_config.db_schema, compression=True) as conn:\n        stmt = conn.execute("SELECT gpu_required(), gpu_required();")\nexcept Exception as e:\n    print(e)', language="python", min_height=100)
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
    If your query contains multiple UDFs, all allowing support CPU fallback, then the GPU accelerator will be assigned to _one_ of the UDFs. However, it is not possible to predict which one.
    """)
    return

@app.cell
def _(mo):
    editor_010 = mo.ui.code_editor(value='with open_pyexasol_connection_with_lang_definitions(ai_lab_config, schema=ai_lab_config.db_schema, compression=True) as conn:\n    res = conn.export_to_pandas("SELECT gpu_optional() as udf1, gpu_optional() as udf2, gpu_optional() as udf3, gpu_optional() as udf4;")\nres', language="python", min_height=100)
    run_010 = mo.ui.run_button(label="Run cell 10")
    mo.vstack([editor_010, run_010])
    return editor_010, run_010

@app.cell
def _(editor_010, lesson, mo, render, run_010):
    mo.stop(not run_010.value)
    render(mo, lesson.run(editor_010.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ### GPU Usage Across UDF Instances

    If there are multiple UDF instances on a data node of a single UDF call within the same query, all those instances will have access to all (GPU) accelerators on this node. To reduce the risk of running out of GPU memory, we recommend that you use _UDF instance limiting_ to control how many accelerators each instance can use, and that you configure the instance limit based on the number of accelerators and the use case.
    """)
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    #### Scalar UDFs
    For Scalar UDFs there is no mechanism to assign a UDF instance to a specific GPU. Hence, we recommend using Scalar UDFs only for _reading_ some GPU device information, but not to perform any processing on the GPUs. A good example is to execute the `nvidia-smi` tool in a scalar UDF.
    """)
    return

@app.cell
def _(mo):
    editor_011 = mo.ui.code_editor(value='sql = textwrap.dedent(f"""\nCREATE OR REPLACE {slc.language_alias} SCALAR SCRIPT\ngpu_nvidia_smi()\nRETURNS VARCHAR(10000) AS\n %perInstanceRequiredAcceleratorDevices GpuNvidia;\n\nimport subprocess\n\ndef run(ctx):\n    cmd = ["nvidia-smi"] #List GPUs\n    process = subprocess.Popen(\n        cmd,\n        stdout=subprocess.PIPE,\n        stderr=subprocess.PIPE,\n        text=True,\n    )\n    exit_code = process.wait()\n    \n    if exit_code != 0:\n        raise Exception(f"nvidia-smi returned non-zero exit code: \'{{process.stderr}}\'")\n    return process.stdout.read()\n\n/\n""")\nwith open_pyexasol_connection_with_lang_definitions(ai_lab_config, schema=ai_lab_config.db_schema, compression=True) as conn:\n    conn.execute(sql)\n\nwith open_pyexasol_connection_with_lang_definitions(ai_lab_config, schema=ai_lab_config.db_schema, compression=True) as conn:\n    res = conn.execute("SELECT gpu_nvidia_smi();").fetchall()\nprint(res[0][0])', language="python", min_height=100)
    run_011 = mo.ui.run_button(label="Run cell 11")
    mo.vstack([editor_011, run_011])
    return editor_011, run_011

@app.cell
def _(editor_011, lesson, mo, render, run_011):
    mo.stop(not run_011.value)
    render(mo, lesson.run(editor_011.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    #### Set UDFs

    For Set UDF it is possible to generate a group per GPU and pass this `GPU id` to the UDF as parameter.

    For this purpose we modify the example from the [Advanced UDF with GPU Support](/?file=exasol-examples/gpu_in_udf/advanced_udf_with_gpu.py) notebook.
    """)
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    First, we need the number of available GPUs. This can be achieved by reading the `EXA_METADATA` parameter `acceleratorDeviceGpuNvidiaCount`.
    """)
    return

@app.cell
def _(mo):
    editor_012 = mo.ui.code_editor(value='with open_pyexasol_connection_with_lang_definitions(ai_lab_config, schema=ai_lab_config.db_schema, compression=True) as conn:\n    nAvailableGPU = conn.execute("SELECT PARAM_VALUE FROM EXA_METADATA WHERE PARAM_NAME=\'acceleratorDeviceGpuNvidiaCount\'").fetchall()[0][0]\nnAvailableGPU', language="python", min_height=100)
    run_012 = mo.ui.run_button(label="Run cell 12")
    mo.vstack([editor_012, run_012])
    return editor_012, run_012

@app.cell
def _(editor_012, lesson, mo, render, run_012):
    mo.stop(not run_012.value)
    render(mo, lesson.run(editor_012.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    Now need modify the "SEMANTIC_JOIN" UDF and add a GPU id parameter:
    ```
    CREATE OR REPLACE {slc.language_alias} SET SCRIPT "SEMANTIC_JOIN"(gpu_id INTEGER, text1 VARCHAR(2000000), text2 VARCHAR(2000000))
    ```

    Also, we set the UDF instance limit to the number of available GPUs, to avoid parallel access from differnt UDF instances to the same GPU.
    ```
    %perNodeAndCallInstanceLimit {{nAvailableGPU}};
    ```

    Finally, we use the given GPU id from the UDF call and specify it when we instantiate the `pytorch` device:
    ```
    gpu_id = df["gpu_id"][0] #Just take the first one. The caller needs to ensure that column gpu_id has only identical values
    device = torch.device(f"cuda:{{gpu_id}}")
    ```
    """)
    return

@app.cell
def _(mo):
    editor_013 = mo.ui.code_editor(value='sql_semantic_join = f"""\n--/\nCREATE OR REPLACE {slc.language_alias} SET SCRIPT "SEMANTIC_JOIN"(gpu_id INTEGER, text1 VARCHAR(2000000), text2 VARCHAR(2000000))\nEMITS(gpu_id INTEGER, text1 VARCHAR(2000000), text2 VARCHAR(2000000), similarity_score DOUBLE) AS\n%perInstanceRequiredAcceleratorDevices GpuNvidia;\n%perNodeAndCallInstanceLimit {nAvailableGPU};\n\nimport pandas as pd\nfrom transformers import AutoTokenizer, AutoModel, Pipeline, pipeline\nimport torch\nimport exasol.bucketfs as bfs\nfrom pathlib import Path\nfrom exasol_transformers_extension.utils import device_management\nfrom exasol.python_extension_common.connections.bucketfs_location import (\n    create_bucketfs_location_from_conn_object)\nfrom exasol_transformers_extension.utils.bucketfs_model_specification import (\n    BucketFSModelSpecification)\nfrom exasol_transformers_extension.utils.huggingface_hub_bucketfs_model_transfer_sp import (\n    HuggingFaceHubBucketFSModelTransferSP)\nfrom exasol_transformers_extension.utils.load_local_model import LoadLocalModel\n\n\ndef get_bucketfs_location(exa, bucketfs_conn_name: str) -> bfs.path.PathLike:\n    return create_bucketfs_location_from_conn_object(\n        exa.get_connection(bucketfs_conn_name))\n\ndef load_transformers_pipline(exa,\n                              bucketfs_conn_name: str,\n                              sub_dir: str,\n                              device: str,\n                              task_type: str,\n                              model_name: str,\n                              model_factory,\n                              tokenizer_factory=AutoTokenizer) -> Pipeline:\n    model_loader = LoadLocalModel(pipeline,\n                                  base_model_factory=model_factory,\n                                  tokenizer_factory=tokenizer_factory,  # type: ignore\n                                  task_type=task_type,\n                                  device=device)    # type: ignore\n\n    model_spec = BucketFSModelSpecification(model_name, task_type, bucketfs_conn_name,\n                                            Path(sub_dir))\n\n    bucketfs_location = get_bucketfs_location(exa, bucketfs_conn_name)\n\n    model_loader.clear_device_memory()\n    model_loader.set_current_model_specification(model_spec)\n    model_loader.set_bucketfs_model_cache_dir(bucketfs_location)\n    return model_loader.load_models()\n\n# Function to calculate embeddings\ndef batch_get_embeddings(batch_texts, model_pipeline, device):\n    # Tokenize the batch of texts\n    inputs = model_pipeline.tokenizer(batch_texts, padding=True, truncation=True, return_tensors=\'pt\').to(device)  # Send to GPU\n    # Get embeddings from the model\n    with torch.no_grad():\n        outputs = model_pipeline.model(**inputs)\n    # Use the outputs pooler_output or last_hidden_state to get the embedding\n    return outputs.pooler_output if \'pooler_output\' in outputs else outputs.last_hidden_state.mean(dim=1)\n\n# Function to compute row-by-row cosine similarity using PyTorch\ndef row_by_row_cosine_similarity_gpu(embeddings1, embeddings2):\n    # Normalized embeddings can be calculated separately\n    normalized_embeddings1 = embeddings1 / embeddings1.norm(dim=1)[:, None]\n    normalized_embeddings2 = embeddings2 / embeddings2.norm(dim=1)[:, None]\n\n    # Compute pair-wise cosine similarity for each corresponding pair\n    similarities = (normalized_embeddings1 * normalized_embeddings2).sum(dim=1)\n    return similarities\n\n\ndef get_model_pipeline(device):\n    return load_transformers_pipline(\n        exa,\n        bucketfs_conn_name=\'{ai_lab_config.bfs_connection_name}\',\n        sub_dir=\'{ai_lab_config.bfs_model_subdir}\',\n        device=device,\n        model_name="sentence-transformers/all-mpnet-base-v2",\n        task_type=\'feature-extraction\',\n        model_factory=AutoModel)\n\ndef run(ctx):\n    \n    # Batch processing configurations\n    batch_size = 100  # Adjust this based on your memory capacity\n    model_pipeline = None\n    while True:\n        df = ctx.get_dataframe(batch_size)\n        if df is None:\n            break\n\n        data1 = df["text1"]\n        data2 = df["text2"]\n        gpu_id = df["gpu_id"][0] #Just take the first one. The caller needs to ensure that column gpu_id has only identical values\n        device = torch.device(f"cuda:{{gpu_id}}")\n        if model_pipeline is None:\n            model_pipeline = get_model_pipeline(device)\n\n        # Compute embeddings for each dataset in batches\n        embeddings1 = batch_get_embeddings(data1.to_list(), model_pipeline, device)\n        embeddings2 = batch_get_embeddings(data2.to_list(), model_pipeline, device)\n\n        # Calculate row-by-row cosine similarity using PyTorch on GPU\n        similarity_scores = row_by_row_cosine_similarity_gpu(embeddings1, embeddings2)\n\n        # Determine matches based on similarity scores (threshold can be adjusted)\n        df["SIMILARITY_SCORE"]=similarity_scores.cpu()\n        ctx.emit(df)\n/\n"""\nwith open_pyexasol_connection_with_lang_definitions(ai_lab_config, schema=ai_lab_config.db_schema, compression=True) as conn:\n    conn.execute(sql_semantic_join)', language="python", min_height=100)
    run_013 = mo.ui.run_button(label="Run cell 13")
    mo.vstack([editor_013, run_013])
    return editor_013, run_013

@app.cell
def _(editor_013, lesson, mo, render, run_013):
    mo.stop(not run_013.value)
    render(mo, lesson.run(editor_013.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    Finally, we modify the SQL query from the Semantic Join query, and group the data by GPU id and Exasol node.
    For this purpose we simply create an integer value between 0 and the number of available GPUs and assign this to each row with:
    ```
    MOD(ROW_NUMBER() OVER (), {nAvailableGPU}) AS GPU_ID
    ```
    Then we add this integer value to the UDF call:
    ```
    "SEMANTIC_JOIN"(GPU_ID, TITLE, TOPIC)
    ```
    The data used to call the UDF is as follows:
    """)
    return

@app.cell
def _(mo):
    editor_014 = mo.ui.code_editor(value='sql = textwrap.dedent(f"""\nSELECT \n    MOD(ROW_NUMBER() OVER (), {nAvailableGPU}) AS GPU_ID, TOPIC, TITLE\nFROM (\n    SELECT \n        distinct TOPIC, TITLE\n    FROM (\n        SELECT distinct title as TITLE FROM NEWS WHERE TITLE IS NOT NULL AND BODY IS NOT NULL\n    )\n    CROSS JOIN (\n        SELECT distinct topic AS TOPIC FROM NEWS WHERE topic IS NOT NULL\n    )\n)\n""")\nwith open_pyexasol_connection_with_lang_definitions(ai_lab_config, schema=ai_lab_config.db_schema, compression=True) as conn:\n    res = conn.export_to_pandas(sql)\nres', language="python", min_height=100)
    run_014 = mo.ui.run_button(label="Run cell 14")
    mo.vstack([editor_014, run_014])
    return editor_014, run_014

@app.cell
def _(editor_014, lesson, mo, render, run_014):
    mo.stop(not run_014.value)
    render(mo, lesson.run(editor_014.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    Now, we call the UDF to calculate the semantic join, distributed safely across multiple GPUs and nodes:
    """)
    return

@app.cell
def _(mo):
    editor_015 = mo.ui.code_editor(value='sql_semantic_join = textwrap.dedent(f"""\nSELECT *\nFROM (\n    SELECT\n        TEXT1 AS TITLE, TEXT2 AS TOPIC,\n        RANK() OVER (PARTITION BY TEXT1 ORDER BY SIMILARITY_SCORE DESC) as r,\n        SIMILARITY_SCORE\n    FROM (\n        SELECT\n            "SEMANTIC_JOIN"(GPU_ID, TITLE, TOPIC)\n        FROM (\n            SELECT \n                MOD(ROW_NUMBER() OVER (), {nAvailableGPU}) AS GPU_ID, TOPIC, TITLE\n            FROM (\n                SELECT \n                    distinct TOPIC, TITLE\n                FROM (\n                    SELECT distinct title as TITLE FROM NEWS WHERE TITLE IS NOT NULL AND BODY IS NOT NULL\n                )\n                CROSS JOIN (\n                    SELECT distinct topic AS TOPIC FROM NEWS WHERE topic IS NOT NULL\n                )\n            )\n        ) GROUP BY iproc(), GPU_ID\n    )\n    WHERE SIMILARITY_SCORE > 0.5\n)\nWHERE r<=5\nORDER BY TITLE, r ASC;\n""")\nwith open_pyexasol_connection_with_lang_definitions(ai_lab_config, schema=ai_lab_config.db_schema, compression=True) as conn:\n    res = conn.export_to_pandas(sql_semantic_join)\nres', language="python", min_height=100)
    run_015 = mo.ui.run_button(label="Run cell 15")
    mo.vstack([editor_015, run_015])
    return editor_015, run_015

@app.cell
def _(editor_015, lesson, mo, render, run_015):
    mo.stop(not run_015.value)
    render(mo, lesson.run(editor_015.value))
    return

if __name__ == "__main__":
    app.run()
