import marimo

__generated_with = "0.25.2"
app = marimo.App()

@app.cell
def _():
    import marimo as mo
    from exakit.nb.example_runtime import Lesson, render
    lesson = Lesson('text_ai/txaie_preprocessing.ipynb')
    return lesson, mo, render

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    # Bundled Exasol lesson: Text AI Preprocessing

    Requires a configured Text AI Extension and its database objects. These services are not installed by opening a notebook.

    Run cells from top to bottom. In Marimo each editable cell has its own Run button; opening a lesson executes no example code. Widget steps retain their Python code; use the matching Jupyter notebook for the original widget UI.

    For dashboards use the kit Data Scientist 03_share flow on Dash Server.

    Source: [Exasol Notebook Connector](https://github.com/exasol/notebook-connector/blob/14e2c7ad088b7109aa21d283e98f3126bbbe27e5/exasol/nb_connector/resources/notebooks/text_ai/txaie_preprocessing.ipynb). MIT license: LICENSE.txt.
    """)
    return

@app.cell
def _(mo):
    editor_001 = mo.ui.code_editor(value="from exakit.nb.example_runtime import bootstrap\nai_lab_config = bootstrap(globals(), 'text_ai/txaie_preprocessing.ipynb')", language="python", min_height=100)
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

    # Text AI Preprocessing


    Here we will demonstrate how the Text AI can be used to build a data-preprocessing workflow. We will be taking a dataset of customer support tickets. This dataset contains unstructured data in the form of ticket descriptions. We will sort these tickets into "urgent" and "not urgent" cases, and find important named entities and keywords within the text. This will be archived using a Text AI Workflow.

    We will also demonstrate the Text AI ability to determine if data was already processed, and skip it if applicable.

    ## Prerequisites

    Prior to using this notebook one needs to complete the following steps:

    1. [Load the Customer Support Ticket Dataset](/?file=exasol-examples/data/data_customer_support.py)
    2. [Initialize the Text AI Extension](/?file=exasol-examples/text_ai/txaie_init.py)
    """)
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ## Natural Language Processing Introduction

    This section contains a short introduction to Natural Language Processing, and the precesses we will use in this notebook.

    ### NLP

    Natural Language Processing, or the processing of so-called "unstructured data" or "free text", is the processing(i.e. classification, retrieving of information) of unannotated language.

    There are tasks in Natural Language Processing (NLP) which seem easy to us humans, but are very hard for a machine to do. For example, inferring the opinion the speaker has about a topic (Opinion Extraction/Mining). Doing these tasks on un-annotated text is even harder. Therefore, multiple ways to annotate a natural language text with additional information were developed. These annotated texts are then better suited for higher-level NLP tasks.
                                                                                                                                                   
    Depending on the amount of data/text which should be processed, annotating by hand is mostly not an option these days, since with increasing dataset sizes the resources needed quickly become unrealistic. Therefore, Exasol Text AI provides you with tools you can use for annotating your data in various ways.
                                                                                                                     
    In this Notebook, we will show you our three default preprocessing workflow steps. Of course, it is possible for you to define your own workflow later on.
    Let's explain these three steps before we dive into how to run the preprocessing.
                                                                                                                     
    ### Topic Classification
                                                                                                                     
    Topic Classification is the task of assigning topics to text/documents/datapoints. In Topic Classification, a given set of topics is used, and each data point is assigned a relevance score and rank for each of the topics. These relevance scores and ranks can then be used to select the best matching topic for each data point.
    Given that a document is about a particular topic, particular words are expected to appear in the document more or less frequently. However, it is not required for the exact words to describe the topic to be found in a text. This means that topics can be inferred, even if their name/description/topic synonyms are not found in the data.

    ![diagramm a document text added topics](images/topics.drawio.png)
    Topic Classification works with a given set of these topics as input and assigns to each a relevance score that the text being about this topic. It is usually trained using supervised learning. It can also be used with Zero-Shot Classification models, which can assign classes/topics which have not been seen during the training. This is opposed to other approaches like topic extraction, which is often unsupervised and does not need a list of topics as input, instead extracting them from the data itself.
                                                                                                                     
    ### Keyword Search
                                                                               
    Keyword Search is about identifying the most relevant words or phrases(Keywords/Keyphrases) from a given text.
    These can then help in further steps, e.g. summarizing the content of texts and recognizing the main topics discussed.
    Keywords or phrases need be present in the text.
    For Example:
    ![diagramm a document text with highlighted keywords](images/keywords.drawio.png)


    ### Named Entity Recognition

    Named entity recognition (NER) is about locating and classify so called "named entities" mentioned in a text document. Depending on the model, entities are e.g. person names, organizations, locations, or vehicles etc., so "things that have names". The model seeks out those entities, returning their positions in the document, as well as their class.

    ### Example Result of 3 Steps

    Let's look at an example of what the output for these three steps might look like combined. For a given document, consider the document content to be "I'm having an issue with the GoPro Hero. It's affecting my productivity.". We may use a topic classifier with the input topic set of "urgent, not urgent" for inferring urgency from ticket content. The NER and Keyword Search do not need additional input, they just work with the document itself. Then the output of a preprocessing pipeline containing all three steps could look something like this:

    ![diagramm showing document text with found entity and keyword and topic](images/document_annotated.drawio.png)
    """)
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    You can verify if the dataset is already available with the query below. It should return `3606`.
    """)
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ## General Setup

    As a first step, we need to get access to the Ai-Lab secret store:
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
    Then we can get the activation SQL for our previously installed Script Language Containers. This will be used to activate those SLCs in order to use their UDFs.

    We also want to import some of the Python functions of the Text AI and Notebook Connector modules.
    """)
    return

@app.cell
def _(mo):
    editor_003 = mo.ui.code_editor(value='from exakit.nb.example_runtime import open_pyexasol_connection\nfrom exasol.nb_connector.text_ai_extension_wrapper import Extraction\nfrom exasol.ai.text.extraction.abstract_extraction import Defaults, Output\nfrom exasol.ai.text.extractors.standard_extractor import StandardExtractor\nfrom exasol.ai.text.extractors.extractor import PipelineExtractor\nfrom exasol.ai.text.extractors.source_table_extractor import SourceTableExtractor, SchemaSource, TableSource, NameSelector', language="python", min_height=100)
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
    The next call will make it possible to run SQL directly in this notebook, in order to easier display the results of our preprocessing. The one below sets the maximum number of columns our SQL statements can display in the notebook.
    """)
    return

@app.cell
def _(mo):
    editor_004 = mo.ui.code_editor(value='from exakit.nb.example_runtime import init_sql as jupysql_init\njupysql_init(ai_lab_config)', language="python", min_height=100)
    run_004 = mo.ui.run_button(label="Run cell 4")
    mo.vstack([editor_004, run_004])
    return editor_004, run_004

@app.cell
def _(editor_004, lesson, mo, render, run_004):
    mo.stop(not run_004.value)
    render(mo, lesson.run(editor_004.value))
    return

@app.cell
def _(mo):
    editor_005 = mo.ui.code_editor(value='%config SqlMagic.displaylimit = 20', language="python", min_height=100)
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
    ## Create an Example Data Source

    We will be using a dataset which holds information on customer support tickets. For loading the dataset, please refer to the [prerequisites](#prerequisites). We will split this data into 2 sets, in order to demonstrate how the preprocessing tasks handle new data being added to a data source.
    """)
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    You can verify if the dataset is already available with the query below. It should return `3606`.
    """)
    return

@app.cell
def _(mo):
    editor_006 = mo.ui.code_editor(value='text_column="TICKET_DESCRIPTION"\nkey_column="TICKET_ID"\ntable="CUSTOMER_SUPPORT_TICKETS"\nschema=ai_lab_config.db_schema', language="python", min_height=100)
    run_006 = mo.ui.run_button(label="Run cell 6")
    mo.vstack([editor_006, run_006])
    return editor_006, run_006

@app.cell
def _(editor_006, lesson, mo, render, run_006):
    mo.stop(not run_006.value)
    render(mo, lesson.run(editor_006.value))
    return

@app.cell
def _(mo):
    editor_007 = mo.ui.code_editor(value='%%sql\nSELECT COUNT(*) FROM "{{schema}}"."{{table}}";', language="python", min_height=100)
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
    ### Create a View on the Data

    This dataset has ~3600 entries. You could run the preprocessing for the whole dataset, but it would take quite some time. Instead, we will create a view containing only a part of the dataset, and use this view as the base for our preprocessing.
    We set the size of this view here. If you want to see how the AI Lab handles bigger datasets on your Exasol instance, you can set the `view_size` higher.
    """)
    return

@app.cell
def _(mo):
    editor_008 = mo.ui.code_editor(value='view="TICKETS_SAMPLE"\nview_size = 10', language="python", min_height=100)
    run_008 = mo.ui.run_button(label="Run cell 8")
    mo.vstack([editor_008, run_008])
    return editor_008, run_008

@app.cell
def _(editor_008, lesson, mo, render, run_008):
    mo.stop(not run_008.value)
    render(mo, lesson.run(editor_008.value))
    return

@app.cell
def _(mo):
    editor_009 = mo.ui.code_editor(value='%%sql\nCREATE OR REPLACE VIEW "{{schema}}"."{{view}}" AS \nSELECT * FROM "{{schema}}"."{{table}}" \nORDER BY "TICKET_ID" \nLIMIT {{view_size}};', language="python", min_height=100)
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
    Lets check the size of our created view:
    """)
    return

@app.cell
def _(mo):
    editor_010 = mo.ui.code_editor(value='%%sql\nSELECT COUNT(*) FROM "{{schema}}"."{{view}}";', language="python", min_height=100)
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
    As you can see, we now have only our defined 10 data points in the view.

    Let's now see what our data contains:
    """)
    return

@app.cell
def _(mo):
    editor_011 = mo.ui.code_editor(value='%%sql\nDESC "{{schema}}"."{{view}}"', language="python", min_height=100)
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
    We can see a ticket ID column, as well as some columns containing information about the customer, like name. There are columns containing some metadata for the ticket itself, such as the purchase date, ticket status and ticket channel. The ticket description contains the actual text of the ticket.
    """)
    return

@app.cell
def _(mo):
    editor_012 = mo.ui.code_editor(value='%%sql\nSELECT \n    TICKET_ID,\n    CUSTOMER_NAME,\n    DATE_OF_PURCHASE,\n    TICKET_SUBJECT, \n    TICKET_DESCRIPTION,\n    TICKET_STATUS,\n    TICKET_CHANNEL\nFROM "{{schema}}"."{{view}}"\nLIMIT 5', language="python", min_height=100)
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
    ### Cleaning up Results of previous Runs of the Notebook
    """)
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    To make sure the tables the preprocessing will use don't already exist, for example from a previous run of this notebook, we are going to drop them.
    First, we define a list of tables to drop:
    """)
    return

@app.cell
def _(mo):
    editor_013 = mo.ui.code_editor(value='# A list of tables which the steps below create automatically. If you run the notebook multiple times they need to be dropped in between.\ntable_list = [\n    "TXAIE_AUDIT_LOG",\n    "DOCUMENTS",\n    f"DOCUMENTS_{schema}_TICKETS_SAMPLE",\n    "NAMED_ENTITY",\n    "NAMED_ENTITY_LOOKUP_ENTITY_TYPE",\n    "NAMED_ENTITY_LOOKUP_SETUP",\n    "KEYWORD_SEARCH",\n    "KEYWORD_SEARCH_LOOKUP_KEYWORD",\n    "KEYWORD_SEARCH_LOOKUP_SETUP",\n    "TOPIC_CLASSIFIER",\n    "TOPIC_CLASSIFIER_LOOKUP_TOPIC",\n    "TOPIC_CLASSIFIER_LOOKUP_SETUP"\n]', language="python", min_height=100)
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
    If you are curious about which tables are generated and how they look, you can find that information in the [Results](#results) section below.
    Next, define a function which drops these tables. Then we call the function.

    **Note:** If you run into technical issues during the running of this notebook, you might want to run the `delete_text_ai_preprocessing_tables` function again, in order to re-run the workflow from scratch. This will ensure all data gets processed again.
    """)
    return

@app.cell
def _(mo):
    editor_014 = mo.ui.code_editor(value='def delete_text_ai_preprocessing_tables():\n    with open_pyexasol_connection(ai_lab_config, compression=True) as conn:\n        for drop_table in table_list:\n            conn.execute(f"""DROP TABLE IF EXISTS "{schema}"."{drop_table}" """)', language="python", min_height=100)
    run_014 = mo.ui.run_button(label="Run cell 14")
    mo.vstack([editor_014, run_014])
    return editor_014, run_014

@app.cell
def _(editor_014, lesson, mo, render, run_014):
    mo.stop(not run_014.value)
    render(mo, lesson.run(editor_014.value))
    return

@app.cell
def _(mo):
    editor_015 = mo.ui.code_editor(value='delete_text_ai_preprocessing_tables()', language="python", min_height=100)
    run_015 = mo.ui.run_button(label="Run cell 15")
    mo.vstack([editor_015, run_015])
    return editor_015, run_015

@app.cell
def _(editor_015, lesson, mo, render, run_015):
    mo.stop(not run_015.value)
    render(mo, lesson.run(editor_015.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ## Download NLP Models

    We will use multiple different open source Hugging Face Transformers models to run our preprocessing with. 
    * For Named Entity Extraction: [guishe/nuner-v2_fewnerd_fine_super](https://huggingface.co/guishe/nuner-v2_fewnerd_fine_super)
    * For Topic Classification: [tasksource/ModernBERT-base-nli](https://huggingface.co/tasksource/ModernBERT-base-nli)
    * For Keyword Extraction: [answerdotai/ModernBERT-base](https://huggingface.co/answerdotai/ModernBERT-base)

    These models were already installed during the [intialization](/?file=exasol-examples/text_ai/txaie_init.py) of Text AI.

    You can download your own models as follows:

    ```python
    from exasol.nb_connector.model_installation import install_model, TransformerModel
    from transformers import AutoModel, AutoModelForTokenClassification, AutoModelForSequenceClassification

    install_model(conf,TransformerModel(
        "your keyword search model", 
        "feature-extraction", AutoModel))
    install_model(conf,TransformerModel(
        "your named entity model", 
        "token-classification", AutoModelForTokenClassification))
    install_model(conf,TransformerModel(
        "your zero-shot classification model",
        "zero-shot-classification", AutoModelForSequenceClassification))
    ```
    """)
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ## Configure the Text AI Workflow

    The Text-AI-Extension allows you to configure a data processing workflow. In this Notebook we will be using a basic example where the workflow is defined by a so called `StandardExtractor`.                                                                                                                    
    #### Configure Default Values

    Here, we will configure how our workflow should run. In general, each NLP extractor has its own configuration parameters. The `Defaults` object is a helper object allowing us to set these parameters once and apply these settings to all extractors.

    How you need to set these defaults will depend on your Database. This demonstration should work on a rather small Docker-DB. Therefore, we set the `batch_size` to only 10, so only 10 rows will be processed at once in each UDF instance, and also our `parallelism_per_node` is set to the low value of 1. `parallelism_per_node` determines how many parallel UDF instances are run on each node of your database. If you have a bigger Database to run this Notebook on, you can try to increase both values.
    The model repository is a data object pointing to the location of the model files we during the extension initailization or the previous step.
    """)
    return

@app.cell
def _(mo):
    editor_016 = mo.ui.code_editor(value='defaults = Defaults(\n    parallelism_per_node=1,\n    batch_size=10\n)', language="python", min_height=100)
    run_016 = mo.ui.run_button(label="Run cell 16")
    mo.vstack([editor_016, run_016])
    return editor_016, run_016

@app.cell
def _(editor_016, lesson, mo, render, run_016):
    mo.stop(not run_016.value)
    render(mo, lesson.run(editor_016.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ### Define the Extractor

    Now we need to define an extractor to run our extraction/preprocessing. We will use a `StandardExtractor` which has 3 standard preprocessing steps built-in, namely the topic classification, keyword search and named entity recognition. It is possible to disable each of these steps in the `StandartExtractor` by setting its model to `None`. You can also use a different model instead of the built-in one, by setting its model to a specific Hugging Face model. But here we will use the `StandartExtractor` as is.

    For the topic classification model we will use the topics "urgent", and "not urgent".
    """)
    return

@app.cell
def _(mo):
    editor_017 = mo.ui.code_editor(value='topics={"urgent", "not urgent"}\n\nstd_extractor =  StandardExtractor(\n                        # If you want to disable a step, set it to None:\n                        # named_entity_recognition_model = None,\n                        # topic_classification_model = None,\n                        \n                        # If you want to use a different(not default) model, set its name:\n                        # keyword_search_model = HuggingFaceModel(name="MY_KEYWORD_SEARCH_MODEL"),\n                        topics=topics\n                    )', language="python", min_height=100)
    run_017 = mo.ui.run_button(label="Run cell 17")
    mo.vstack([editor_017, run_017])
    return editor_017, run_017

@app.cell
def _(editor_017, lesson, mo, render, run_017):
    mo.stop(not run_017.value)
    render(mo, lesson.run(editor_017.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    We will also need a `SourceTableExtractor`, which holds information on which data we want to use as a source for our preprocessing, and feed it to the `StandardExtractor`.
    We give it our schema and view as a data source, and tell it to run the preprocessing on the column `TICKET_DESCRIPTION`, since that is where the Natural Text part of our data is. We also tell it to use the `TICKET_ID` column as an id/key.
    """)
    return

@app.cell
def _(mo):
    editor_018 = mo.ui.code_editor(value='text_column="TICKET_DESCRIPTION"\nkey_column="TICKET_ID"\n\nsrc_extractor = SourceTableExtractor(\n                        name=\'DOCUMENTS\',\n                        sources=[\n                            SchemaSource(\n                                db_schema=NameSelector(pattern=schema),\n                                tables=[\n                                    TableSource(\n                                        table=NameSelector(pattern=view),\n                                        columns=[NameSelector(pattern=text_column)],\n                                        keys=[NameSelector(pattern=key_column)]\n                                    )\n                                ]\n                            )\n                        ]\n                    )', language="python", min_height=100)
    run_018 = mo.ui.run_button(label="Run cell 18")
    mo.vstack([editor_018, run_018])
    return editor_018, run_018

@app.cell
def _(editor_018, lesson, mo, render, run_018):
    mo.stop(not run_018.value)
    render(mo, lesson.run(editor_018.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    Now, we can give these two extractors as steps to a `PipelineExtractor`, which will build a pipeline out of them which will execute them after each other and feed the output of the first step into the second step:
    """)
    return

@app.cell
def _(mo):
    editor_019 = mo.ui.code_editor(value='p_extractor = PipelineExtractor(\n                steps=[\n                    src_extractor,\n                    std_extractor\n                ]\n            )', language="python", min_height=100)
    run_019 = mo.ui.run_button(label="Run cell 19")
    mo.vstack([editor_019, run_019])
    return editor_019, run_019

@app.cell
def _(editor_019, lesson, mo, render, run_019):
    mo.stop(not run_019.value)
    render(mo, lesson.run(editor_019.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    Next, we will wrap our `PipelineExtractor* in an `Extraction`. This will allow us to configure where the output should be stored, which defaults to use and to run the extractor.

    We feed it our `PipelineExtractor` as the extractor, tell it to put the `Output` into our schema, and also give it our `Defaults`.
    """)
    return

@app.cell
def _(mo):
    editor_020 = mo.ui.code_editor(value='extraction = Extraction(extractor=p_extractor,\n                        output=Output(db_schema=schema),\n                        defaults=defaults)', language="python", min_height=100)
    run_020 = mo.ui.run_button(label="Run cell 20")
    mo.vstack([editor_020, run_020])
    return editor_020, run_020

@app.cell
def _(editor_020, lesson, mo, render, run_020):
    mo.stop(not run_020.value)
    render(mo, lesson.run(editor_020.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    Then the only step left is to define a convenience function which calls our preprocessing, and then run it in the next section.
    """)
    return

@app.cell
def _(mo):
    editor_021 = mo.ui.code_editor(value='def run_text_ai_preprocessing():\n    extraction.run(ai_lab_config)', language="python", min_height=100)
    run_021 = mo.ui.run_button(label="Run cell 21")
    mo.vstack([editor_021, run_021])
    return editor_021, run_021

@app.cell
def _(editor_021, lesson, mo, render, run_021):
    mo.stop(not run_021.value)
    render(mo, lesson.run(editor_021.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ## Run the Preprocessing

    Time to run our preprocessing. First, let's verify how many entries our view has:
    """)
    return

@app.cell
def _(mo):
    editor_022 = mo.ui.code_editor(value='%%sql\nSELECT COUNT(ALL TICKET_ID) FROM "{{schema}}"."{{view}}";', language="python", min_height=100)
    run_022 = mo.ui.run_button(label="Run cell 22")
    mo.vstack([editor_022, run_022])
    return editor_022, run_022

@app.cell
def _(editor_022, lesson, mo, render, run_022):
    mo.stop(not run_022.value)
    render(mo, lesson.run(editor_022.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    Then we call our preprocessing function. This will use our view as input, and produce new tables and views using the models we installed into the Exasol. 

    Also, take note of the time this operation takes on your setup.
    """)
    return

@app.cell
def _(mo):
    editor_023 = mo.ui.code_editor(value='%%time\nrun_text_ai_preprocessing()', language="python", min_height=100)
    run_023 = mo.ui.run_button(label="Run cell 23")
    mo.vstack([editor_023, run_023])
    return editor_023, run_023

@app.cell
def _(editor_023, lesson, mo, render, run_023):
    mo.stop(not run_023.value)
    render(mo, lesson.run(editor_023.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    **Note**: If the previous operation fails with an error indicating a lost connection, please increase the size of your database and try again. The models are each around 1-2 GB in size and also need that much main memory on each node of your Database.
    """)
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ## Results

    Now, we will take a look at some of the tables and views our preprocessing has created for us. 
    First, let's look at the tables created by our preprocessing:
    """)
    return

@app.cell
def _(mo):
    editor_024 = mo.ui.code_editor(value="%%sql\nSELECT TABLE_SCHEMA, TABLE_NAME FROM EXA_ALL_TABLES WHERE TABLE_SCHEMA='{{schema}}'", language="python", min_height=100)
    run_024 = mo.ui.run_button(label="Run cell 24")
    mo.vstack([editor_024, run_024])
    return editor_024, run_024

@app.cell
def _(editor_024, lesson, mo, render, run_024):
    mo.stop(not run_024.value)
    render(mo, lesson.run(editor_024.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    As you can see, there are a number of new tables related to our preprocessing. There is our original data table `CUSTOMER_SUPPORT_TICKETS`, and a new log table `TXAIE_AUDIT_LOG` which we will take a closer look at below. The `DOCUMENTS` table contains our input texts together with an identifying Span, we will take a look at that as well.
     There is also a `DOCUMENTS_AI_LAB_TICKETS_SAMPLE` table, which contains IDs of the input text and documents, as well as the name of the column the input text originated from.
    This enables you to trace back documents(and their associated results) to the original input data point.

    And then there are 3 tables per step of our preprocessing. A main output table named after the preprocessing step, and some support tables. Multiple tables are required because the output content is usually normalized.
     The support tables are lookup tables and have names formatted like `<main_table_name>_LOOKUP_<normalized_column_name>`. We won't look at them in detail, but if you are curious, feel free to look at the contents of these tables on your own.
     Later we will discuss the contents of VIEWs build on top of these tables, which present them in a de-normalised form.

    If we want to find out how these new tables are structured, we can get a description from the Exasol Database. For example, let's see how the resulting `DOCUMENTS` table looks like.

    ### DOCUMENTS Table
    """)
    return

@app.cell
def _(mo):
    editor_025 = mo.ui.code_editor(value='%%sql\nDESC "{{schema}}".DOCUMENTS', language="python", min_height=100)
    run_025 = mo.ui.run_button(label="Run cell 25")
    mo.vstack([editor_025, run_025])
    return editor_025, run_025

@app.cell
def _(editor_025, lesson, mo, render, run_025):
    mo.stop(not run_025.value)
    render(mo, lesson.run(editor_025.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    It looks like this table contains a `TEXT_DOC_ID`, `TEXT_CHAR_BEGIN`, `TEXT_CHAR_END` and a `TEXT` column.
    The `TEXT` column includes the text of the document.
    `TEXT_DOC_ID` is an ID assigned to each document.
     `TEXT_CHAR_BEGIN` and `TEXT_CHAR_END` indicate which parts of the original document each specific row contains. This triplet of `TEXT_DOC_ID`, `TEXT_CHAR_BEGIN` and `TEXT_CHAR_END` is called a "Span", and together builds an identifier for a section of text. You will encounter them for a lot of text-subsections. For example, found keywords contained in a text are also identified by a span in our result tables (see below).
                                                                                                                                                        
    The usage of these Spans allows you to do various operations on top of these results, such as joining results on the document-id, or checking the order in which keywords appear in a document.

    We can also check the number of unique TEXT_DOC_IDs in our table:
    """)
    return

@app.cell
def _(mo):
    editor_026 = mo.ui.code_editor(value='%%sql\nSELECT COUNT(ALL text_doc_id) FROM "{{schema}}".DOCUMENTS;', language="python", min_height=100)
    run_026 = mo.ui.run_button(label="Run cell 26")
    mo.vstack([editor_026, run_026])
    return editor_026, run_026

@app.cell
def _(editor_026, lesson, mo, render, run_026):
    mo.stop(not run_026.value)
    render(mo, lesson.run(editor_026.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    It's identical to the number of rows in our input view. So all the data was converted successfully.

    Now, let's look at what the content of our table looks like:
    """)
    return

@app.cell
def _(mo):
    editor_027 = mo.ui.code_editor(value='%%sql\nSELECT * FROM "{{schema}}".DOCUMENTS WHERE TEXT_DOC_ID < 5', language="python", min_height=100)
    run_027 = mo.ui.run_button(label="Run cell 27")
    mo.vstack([editor_027, run_027])
    return editor_027, run_027

@app.cell
def _(editor_027, lesson, mo, render, run_027):
    mo.stop(not run_027.value)
    render(mo, lesson.run(editor_027.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ## Resulting Views

    There are also some new views:
    """)
    return

@app.cell
def _(mo):
    editor_028 = mo.ui.code_editor(value='%%sql\nSELECT VIEW_SCHEMA, VIEW_NAME FROM EXA_ALL_VIEWS', language="python", min_height=100)
    run_028 = mo.ui.run_button(label="Run cell 28")
    mo.vstack([editor_028, run_028])
    return editor_028, run_028

@app.cell
def _(editor_028, lesson, mo, render, run_028):
    mo.stop(not run_028.value)
    render(mo, lesson.run(editor_028.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    Text AI stores the results of the three preprocessing steps in tables, which contain the data in normalized form. So, for instance, instead of the topic name you will see a number in the table. The names are collected in a supporting table, named something like XYZ_LOOKUP.
    For easier usage, Text AI creates views which join the respective tables together to provide human-readable information. Such a view is created for each of the preprocessing steps.

    The `DOCUMENTS_AI_LAB_TICKETS_SAMPLE_VIEW` is a view on top of our input data, with the addition of the span identifier(`TEXT_DOC_ID`, `TEXT_CHAR_BEGIN`, `TEXT_CHAR_END`) for the text column of each row. This can be used to join the original data with the preprocessing results.

    ![A diagramm showing multiple Table names with their respective columns. Starting at "CUSTOMER_SUPPORT_TICKETS" folowed by "TICKETS_SAMPLE", then flowing to "DOCUMENTS" and "DOCUMENTS_AI_LAB_TICKETS_SAMPLE_VIEW". The columns containing the text document span are highlighted.](images/data_model_1.drawio.png)

    Let's take a closer look at the results of the topic classification step in our preprocessing now. These can be found in the view `TOPIC_CLASSIFIER_VIEW`.

    ### Topic Classifier View
    """)
    return

@app.cell
def _(mo):
    editor_029 = mo.ui.code_editor(value='%%sql\nDESC "{{schema}}".TOPIC_CLASSIFIER_VIEW', language="python", min_height=100)
    run_029 = mo.ui.run_button(label="Run cell 29")
    mo.vstack([editor_029, run_029])
    return editor_029, run_029

@app.cell
def _(editor_029, lesson, mo, render, run_029):
    mo.stop(not run_029.value)
    render(mo, lesson.run(editor_029.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    This view contains the cross product of the input text and the topics. For each text-topic pair, it provides the computed `TOPIC_SCORE` between the text and the topic. The `TOPIC_SCORE` approximates a normalized relevance of the text with the topic.

    The value in the `TOPIC_RANK` column ranks the topics for each source document by their `TOPIC_SCORE` value. For our example, we had only two topics, so each document was assigned each of the topics, with different scores. The one with the higher score for a given document will have rank 1, the one with the lower score will have rank 2.

    There is also a column for error messages encountered during classification, as well as a `SETUP` column documenting which setup(i.e. model, model-settings) where used to obtain this result.

    As you remember, we wanted to use the classifier to differentiate our user tickets into "urgent" issues and "non-urgent" issues. So those are the topics we expect to see in the results. Let's check how these results look:
    """)
    return

@app.cell
def _(mo):
    editor_030 = mo.ui.code_editor(value='%%sql\nSELECT * FROM "{{schema}}".TOPIC_CLASSIFIER_VIEW LIMIT 5', language="python", min_height=100)
    run_030 = mo.ui.run_button(label="Run cell 30")
    mo.vstack([editor_030, run_030])
    return editor_030, run_030

@app.cell
def _(editor_030, lesson, mo, render, run_030):
    mo.stop(not run_030.value)
    render(mo, lesson.run(editor_030.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    Next, we look at the identified named entities for our input documents. These can be found in the `NAMED_ENTITY_VIEW`.
    ### Named Entity View:
    """)
    return

@app.cell
def _(mo):
    editor_031 = mo.ui.code_editor(value='%%sql\nDESC "{{schema}}".NAMED_ENTITY_VIEW', language="python", min_height=100)
    run_031 = mo.ui.run_button(label="Run cell 31")
    mo.vstack([editor_031, run_031])
    return editor_031, run_031

@app.cell
def _(editor_031, lesson, mo, render, run_031):
    mo.stop(not run_031.value)
    render(mo, lesson.run(editor_031.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    Similar to the `TOPIC_CLASSIFIER_VIEW`, the `NAMED_ENTITY_VIEW` also has the Span(`TEXT_DOC_ID`, `TEXT_CHAR_BEGIN`, `TEXT_CHAR_END`) identifying the input document the entity was found in. Then there are the found named entities in the `ENTITY` column, as well as an `ENTITY_TYPE` and an `ENTITY_SCORE`. The `ENTITY_TYPE` and `ENTITY_SCORE` are assigned to the entity by the model. Additionally, we also have an identifying span for the entity itself: `ENTITY_DOC_ID`, `ENTITY_CHAR_BEGIN`, `ENTITY_CHAR_END`. This span represents exactly where in our input data this entity was found.

    ![a text with an id number. the text containings the named entity subtext "GoPro Hero". from the id, subtext begin and subtext end arrows are pointing to the id,begin,end of the entity span.](images/entity_span.drawio.png)

    Since the named entity was found in the text identified by `TEXT_DOC_ID, TEXT_CHAR_BEGIN, TEXT_CHAR_END`, it follows that `TEXT_DOC_ID`=`ENTITY_DOC_ID` for a given row. Similarly, both `ENTITY_CHAR_BEGIN` and `ENTITY_CHAR_END` are between `TEXT_CHAR_BEGIN` and `TEXT_CHAR_END`. You can use these spans for further processing down the line. For example, you could check how close together named entities of the same document were found, and then check if certain named entity clusters are indicative of different topics. However, this post-processing is not part of this tutorial.

    The `NAMED_ENTITY_VIEW` also includes an error message column and a setup column like the `TOPIC_CLASSIFIER_VIEW` above.
    """)
    return

@app.cell
def _(mo):
    editor_032 = mo.ui.code_editor(value='%config SqlMagic.displaylimit = 10 # we set this lower to the show only a preview of the views', language="python", min_height=100)
    run_032 = mo.ui.run_button(label="Run cell 32")
    mo.vstack([editor_032, run_032])
    return editor_032, run_032

@app.cell
def _(editor_032, lesson, mo, render, run_032):
    mo.stop(not run_032.value)
    render(mo, lesson.run(editor_032.value))
    return

@app.cell
def _(mo):
    editor_033 = mo.ui.code_editor(value='%%sql\nSELECT TEXT_DOC_ID, \n    TEXT_CHAR_BEGIN, \n    TEXT_CHAR_END,\n    ENTITY, \n    ENTITY_TYPE, \n    ENTITY_SCORE, \n    ENTITY_DOC_ID, \n    ENTITY_CHAR_BEGIN, \n    ENTITY_CHAR_END \nFROM "{{schema}}".NAMED_ENTITY_VIEW', language="python", min_height=100)
    run_033 = mo.ui.run_button(label="Run cell 33")
    mo.vstack([editor_033, run_033])
    return editor_033, run_033

@app.cell
def _(editor_033, lesson, mo, render, run_033):
    mo.stop(not run_033.value)
    render(mo, lesson.run(editor_033.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ### Keyword-Search View

    Lastly, our preprocessing created a view containing the results of the keyword search step, the `KEYWORD_SEARCH_VIEW`. This one is structured similar to the `NAMED_ENTITY_VIEW`:
    """)
    return

@app.cell
def _(mo):
    editor_034 = mo.ui.code_editor(value='%%sql\nDESC "{{schema}}".KEYWORD_SEARCH_VIEW', language="python", min_height=100)
    run_034 = mo.ui.run_button(label="Run cell 34")
    mo.vstack([editor_034, run_034])
    return editor_034, run_034

@app.cell
def _(editor_034, lesson, mo, render, run_034):
    mo.stop(not run_034.value)
    render(mo, lesson.run(editor_034.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    The `TEXT_DOC_ID`, `TEXT_CHAR_BEGIN` and `TEXT_CHAR_END` are again the input document span. But instead of an entity with an entity-score and an entity span, we now have a keyword column, a keyword score and a span(`KEYWORD_DOC_ID`, `KEYWORD_CHAR_BEGIN`, `KEYWORD_CHAR_END`) identifying the found keyword in the text. Then, of course, the `ERROR_MESSAGE` and `SETUP` columns.
    """)
    return

@app.cell
def _(mo):
    editor_035 = mo.ui.code_editor(value='%%sql\nSELECT TEXT_DOC_ID, \n    TEXT_CHAR_BEGIN, \n    TEXT_CHAR_END,\n    KEYWORD, \n    KEYWORD_SCORE, \n    KEYWORD_DOC_ID, \n    KEYWORD_CHAR_BEGIN, \n    KEYWORD_CHAR_END \nFROM "{{schema}}".KEYWORD_SEARCH_VIEW WHERE TEXT_DOC_ID < 5', language="python", min_height=100)
    run_035 = mo.ui.run_button(label="Run cell 35")
    mo.vstack([editor_035, run_035])
    return editor_035, run_035

@app.cell
def _(editor_035, lesson, mo, render, run_035):
    mo.stop(not run_035.value)
    render(mo, lesson.run(editor_035.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    You might notice some seemingly duplicated keywords for a given document. But take a look at the keyword spans of those "duplicates". They are different. This means the same keyword was found multiple times in the same document.

    ### Result Summary

    Here is an overview of the data model our preprocessing created.
    
    ![A diagramm showing multiple Table names with their respective columns. Starting at "DOCUMENTS" and then the three result views. The columns containg the text document span are highlighted.](images/data_model_2.drawio.png)


    ## Adding Data to Source View

    Now, let's try and run the preprocessing again, using the exact same input.
    """)
    return

@app.cell
def _(mo):
    editor_036 = mo.ui.code_editor(value='%%time\nrun_text_ai_preprocessing()', language="python", min_height=100)
    run_036 = mo.ui.run_button(label="Run cell 36")
    mo.vstack([editor_036, run_036])
    return editor_036, run_036

@app.cell
def _(editor_036, lesson, mo, render, run_036):
    mo.stop(not run_036.value)
    render(mo, lesson.run(editor_036.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    See how quickly it runs this time? This is because the Text AI does not compute results already computed in previous runs. We can test this behaviour further. Let's add more entries to our dataset, and see and see how long the preprocessing takes then.

    So, in the next call let's double the data in our input view:
    """)
    return

@app.cell
def _(mo):
    editor_037 = mo.ui.code_editor(value='%%sql\nCREATE OR REPLACE VIEW "{{schema}}"."{{view}}" AS \nSELECT * FROM "{{schema}}"."{{table}}" \nORDER BY "TICKET_ID" \nLIMIT {{view_size}}*2;', language="python", min_height=100)
    run_037 = mo.ui.run_button(label="Run cell 37")
    mo.vstack([editor_037, run_037])
    return editor_037, run_037

@app.cell
def _(editor_037, lesson, mo, render, run_037):
    mo.stop(not run_037.value)
    render(mo, lesson.run(editor_037.value))
    return

@app.cell
def _(mo):
    editor_038 = mo.ui.code_editor(value='%%sql\nSELECT COUNT(ALL TICKET_ID) FROM "{{schema}}"."{{view}}";', language="python", min_height=100)
    run_038 = mo.ui.run_button(label="Run cell 38")
    mo.vstack([editor_038, run_038])
    return editor_038, run_038

@app.cell
def _(editor_038, lesson, mo, render, run_038):
    mo.stop(not run_038.value)
    render(mo, lesson.run(editor_038.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    Once we run the preprocessing again, you would expect this run to take twice as long as the first run we did. However, thanks to the way the Text AI is implemented, it takes only roughly the same time as the first run. Text AI detects which documents where already processed and only processes new documents.
    """)
    return

@app.cell
def _(mo):
    editor_039 = mo.ui.code_editor(value='%%time\nrun_text_ai_preprocessing()', language="python", min_height=100)
    run_039 = mo.ui.run_button(label="Run cell 39")
    mo.vstack([editor_039, run_039])
    return editor_039, run_039

@app.cell
def _(editor_039, lesson, mo, render, run_039):
    mo.stop(not run_039.value)
    render(mo, lesson.run(editor_039.value))
    return

@app.cell
def _(mo):
    editor_040 = mo.ui.code_editor(value='%%sql\nSELECT COUNT (*) FROM "{{schema}}".DOCUMENTS;', language="python", min_height=100)
    run_040 = mo.ui.run_button(label="Run cell 40")
    mo.vstack([editor_040, run_040])
    return editor_040, run_040

@app.cell
def _(editor_040, lesson, mo, render, run_040):
    mo.stop(not run_040.value)
    render(mo, lesson.run(editor_040.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    Remember, the processing time is dependent on a lot of factors, such as the actual size of the data points, the batch size, parallelism per node, as well as available memory and number of nodes of the used Exasol Database. So the actual speedup you experience will differ from case to case.

    If you want to experiment with this further, feel free to, for example, add even more data. For this Notebook we did not demonstrate this, because the calls take a long time for demonstration purposes.

    ## Audit Log

    Lastly, let's look at the audit log table Text AI has generated for us. This is a table documenting each run Text AI does on our ExasolDatabase. It contains information on runtime, how mana data entries were used or created, and error messages. This can be very helpful if you suspect a problem with one of your pipelines and want to know where it is coming from. Or if you are interested in seeing how much data came from a specific step, or which of the pipeline steps is taking too long.
    """)
    return

@app.cell
def _(mo):
    editor_041 = mo.ui.code_editor(value='%config SqlMagic.displaylimit = 20', language="python", min_height=100)
    run_041 = mo.ui.run_button(label="Run cell 41")
    mo.vstack([editor_041, run_041])
    return editor_041, run_041

@app.cell
def _(editor_041, lesson, mo, render, run_041):
    mo.stop(not run_041.value)
    render(mo, lesson.run(editor_041.value))
    return

@app.cell
def _(mo):
    editor_042 = mo.ui.code_editor(value='%%sql\nDESC "{{schema}}".TXAIE_AUDIT_LOG', language="python", min_height=100)
    run_042 = mo.ui.run_button(label="Run cell 42")
    mo.vstack([editor_042, run_042])
    return editor_042, run_042

@app.cell
def _(editor_042, lesson, mo, render, run_042):
    mo.stop(not run_042.value)
    render(mo, lesson.run(editor_042.value))
    return

@app.cell
def _(mo):
    editor_043 = mo.ui.code_editor(value='from pandas import option_context\nwith open_pyexasol_connection(ai_lab_config, compression=True) as conn:\n    audit_log = conn.export_to_pandas(f"""\n        SELECT \n            RUN_ID,\n            DB_OBJECT_NAME,\n            EVENT_NAME,\n            ROW_COUNT,\n            LOG_TIMESTAMP \n        FROM "{schema}".TXAIE_AUDIT_LOG\n    """)\n    with option_context(\'display.max_rows\', 20, \'display.max_colwidth\', 1000):\n        display(audit_log)', language="python", min_height=100)
    run_043 = mo.ui.run_button(label="Run cell 43")
    mo.vstack([editor_043, run_043])
    return editor_043, run_043

@app.cell
def _(editor_043, lesson, mo, render, run_043):
    mo.stop(not run_043.value)
    render(mo, lesson.run(editor_043.value))
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    You can now continue with the [Text AI Analytics Notebook](/?file=exasol-examples/text_ai/txaie_analytics.py).
    """)
    return

if __name__ == "__main__":
    app.run()
