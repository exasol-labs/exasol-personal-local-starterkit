import marimo

__generated_with = "0.25.2"
app = marimo.App()

@app.cell
def _():
    import marimo as mo
    from exakit.nb.example_runtime import Lesson, render
    lesson = Lesson('00_library.ipynb')
    return lesson, mo, render

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    # Exasol example library

    All 50 notebooks from the official Notebook Connector collection are bundled here, with their supporting files.

    Start with main_config, then first_steps. Data loaders prepare the tables used by the SQL, Ibis and scikit-learn lessons. Tutorial tables use EXAKIT_EXAMPLES.

    Marimo: run the editable cells in order using each cell's Run button. This preserves Python variables and SQL magics without automatically running downloads or installation commands. Jupyter widget controls are available in the matching Jupyter version.

    GPU, Transformers, Text AI and custom SLC tutorials need additional setup and are marked below. Cloud and external-source examples are reference only; the starter kit does not configure those integrations.

    ## Cloud

    Reference only: cloud storage and virtual-schema integration belong to separate work. These cells are not enabled by the local kit.

    - [Importing data from cloud storage](/?file=exasol-examples/cloud/01_import_data.py)
    - [Create Virtual Schema](/?file=exasol-examples/cloud/02_s3_vs_reuters.py)
    - [Cloud Storage Extension Configuration](/?file=exasol-examples/cloud/cloud_store_config.py)
    - [S3 Virtual Schema configuration](/?file=exasol-examples/cloud/s3_vs_setup.py)

    ## Gpu In Udf

    Requires a GPU-capable Exasol host and GPU SLC. The local Mac kit does not provision these.

    - [Advanced Udf With Gpu](/?file=exasol-examples/gpu_in_udf/advanced_udf_with_gpu.py)
    - [Basic Udf With Gpu](/?file=exasol-examples/gpu_in_udf/basic_udf_with_gpu.py)
    - [GPU Resource Considerations](/?file=exasol-examples/gpu_in_udf/gpu_resource_considerations.py)
    - [Setup Script Language Container with GPU Support](/?file=exasol-examples/gpu_in_udf/setup.py)
    - [Using GPU's in UDF's](/?file=exasol-examples/gpu_in_udf/using_gpu_in_udf.py)

    ## Transformers

    Requires a configured Transformers Extension, model downloads and its language container. These services are not installed by opening a notebook.

    - [Fill-Mask model](/?file=exasol-examples/transformers/masked_modelling.py)
    - [Model Management](/?file=exasol-examples/transformers/model_management.py)
    - [Question answering with text generation model](/?file=exasol-examples/transformers/question_answering.py)
    - [Text classification model](/?file=exasol-examples/transformers/sequence_classification.py)
    - [Transformer Extension initialization](/?file=exasol-examples/transformers/te_init.py)
    - [Introduction](/?file=exasol-examples/transformers/te_introduction.py)
    - [Generative text model](/?file=exasol-examples/transformers/text_generation.py)
    - [Token classifier model](/?file=exasol-examples/transformers/token_classification.py)
    - [Translation model](/?file=exasol-examples/transformers/translation.py)
    - [Hugging Face credentials UI](/?file=exasol-examples/transformers/utils/te_init_ui.py)
    - [Zero-shot classification model](/?file=exasol-examples/transformers/zero_shot_classification.py)

    ## Text Ai

    Requires a configured Text AI Extension and its database objects. These services are not installed by opening a notebook.

    - [Data Analysis with Text AI](/?file=exasol-examples/text_ai/txaie_analytics.py)
    - [Text AI Extension Initialization](/?file=exasol-examples/text_ai/txaie_init.py)
    - [Introduction](/?file=exasol-examples/text_ai/txaie_introduction.py)
    - [Text AI Preprocessing](/?file=exasol-examples/text_ai/txaie_preprocessing.py)

    ## Script Languages Container

    Requires Docker or Podman, SLC tooling and substantial free disk. Container installation can restart the database. Prefer exakit udf-build for the kit flow.

    - [Advanced topics](/?file=exasol-examples/script_languages_container/advanced.py)
    - [Configure Tutorial Script Languages Container](/?file=exasol-examples/script_languages_container/configure_slc_repository.py)
    - [Customize a flavor](/?file=exasol-examples/script_languages_container/customize.py)
    - [Export the flavor as is](/?file=exasol-examples/script_languages_container/export_as_is.py)
    - [Test the new Script-Languages-Container](/?file=exasol-examples/script_languages_container/test_slc.py)
    - [Using the Script-Languages Container Tool](/?file=exasol-examples/script_languages_container/using_the_script_languages_container_tool.py)
    - [File System Ui](/?file=exasol-examples/script_languages_container/utils/file_system_ui.py)

    ## Sklearn

    Load the matching Abalone or Telescope data notebook first. Prediction requires udf-devkit and the PYTHON3_ML runtime. Models use the local file bucket.

    - [Fix the Version of Python Library Scikit-learn](/?file=exasol-examples/sklearn/sklearn_fix_version.py)
    - [Introduction](/?file=exasol-examples/sklearn/sklearn_introduction.py)
    - [Predicting with Regression Model](/?file=exasol-examples/sklearn/sklearn_predict_abalone.py)
    - [Predicting with Classification Model](/?file=exasol-examples/sklearn/sklearn_predict_telescope.py)
    - [Generic Prediction UDF](/?file=exasol-examples/sklearn/sklearn_predict_udf.py)
    - [Training Regression Model](/?file=exasol-examples/sklearn/sklearn_train_abalone.py)
    - [Training Classification Model](/?file=exasol-examples/sklearn/sklearn_train_telescope.py)

    ## Data

    Downloads the tutorial dataset when you run the loader. Tutorial tables are kept in EXAKIT_EXAMPLES, separately from the persona datasets.

    - [Abalone](/?file=exasol-examples/data/data_abalone.py)
    - [List of available data to load](/?file=exasol-examples/data/data_content.py)
    - [Customer Support Ticket Dataset](/?file=exasol-examples/data/data_customer_support.py)
    - [US Flights](/?file=exasol-examples/data/data_flights.py)
    - [MAGIC Gamma Telescope](/?file=exasol-examples/data/data_telescope.py)
    - [Flight Utils](/?file=exasol-examples/data/utils/flight_utils.py)

    ## Ibis

    Requires the US_FLIGHTS and US_AIRLINES tutorial tables. Run first_steps or the flight data loader first.

    - [Working with Exasol using IBIS dataframe library.](/?file=exasol-examples/ibis/quickstart.py)

    ## Jupysql

    Requires the US_FLIGHTS and US_AIRLINES tutorial tables. SQL magics are supported in Jupyter and the Marimo cell runner.

    - [Working with Exasol using JupySQL](/?file=exasol-examples/jupysql/quickstart.py)

    ## Pyexasol

    Requires the flight tutorial tables. Reads and writes tutorial tables and local export files.

    - [Working with Exasol Using the PyExasol Connector](/?file=exasol-examples/pyexasol/roundtrip_import_and_export.py)

    ## Getting started

    Uses the kit encrypted connection. Database examples use EXAKIT_EXAMPLES. Later sections may need tutorial downloads or the ML UDF add-on.

    - [First Steps](/?file=exasol-examples/first_steps.py)
    - [Main Configuration](/?file=exasol-examples/main_config.py)
    - [Welcome to the Exasol AI Lab](/?file=exasol-examples/start.py)
    """)
    return

if __name__ == "__main__":
    app.run()
