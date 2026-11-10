import marimo

__generated_with = "0.25.2"
app = marimo.App()

@app.cell
def _():
    import marimo as mo
    from exakit.nb.example_runtime import Lesson, render
    lesson = Lesson('transformers/question_answering.ipynb')
    return lesson, mo, render

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    # Bundled Exasol lesson: Question answering with text generation model

    Requires a configured Transformers Extension, model downloads and its language container. These services are not installed by opening a notebook.

    Run cells from top to bottom. In Marimo each editable cell has its own Run button; opening a lesson executes no example code. Widget steps retain their Python code; use the matching Jupyter notebook for the original widget UI.

    For dashboards use the kit Data Scientist 03_share flow on Dash Server.

    Source: [Exasol Notebook Connector](https://github.com/exasol/notebook-connector/blob/14e2c7ad088b7109aa21d283e98f3126bbbe27e5/exasol/nb_connector/resources/notebooks/transformers/question_answering.ipynb). MIT license: LICENSE.txt.
    """)
    return

@app.cell
def _(mo):
    editor_001 = mo.ui.code_editor(value="from exakit.nb.example_runtime import bootstrap\nai_lab_config = bootstrap(globals(), 'transformers/question_answering.ipynb')", language="python", min_height=100)
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

    # Question answering with text generation model

    In this notebook, we will load and use text-generation language models that can retrieve the answer to a question from a given text.  Learn more about the Text Generation task <a href="https://huggingface.co/tasks/text-generation" target="_blank" rel="noopener">here</a>. Please also refer to the Transformer Extension <a href="https://github.com/exasol/transformers-extension/blob/main/doc/user_guide/user_guide.md" target="_blank" rel="noopener">User Guide</a> to find more information about the UDFs used in this notebook.

    We will be running SQL queries using <a href="https://github.com/ploomber/jupysql" target="_blank" rel="noopener">JupySQL</a>SQL Magic.

    ## Prerequisites

    Prior to using this notebook the following steps need to be completed:
    1. [Configure the AI Lab](/?file=exasol-examples/main_config.py).
    2. [Initialize the Transformer Extension](/?file=exasol-examples/transformers/te_init.py).

    ## Setup

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
    Let's bring up JupySQL and connect to the database via SQLAlchemy. Please refer to the documentation of <a href="https://github.com/exasol/sqlalchemy-exasol" target="_blank" rel="noopener">sqlalchemy-exasol</a> for details on how to connect to the database using the Exasol SQLAlchemy driver.
    """)
    return

@app.cell
def _(mo):
    editor_003 = mo.ui.code_editor(value='from exakit.nb.example_runtime import init_sql as jupysql_init\njupysql_init(ai_lab_config)', language="python", min_height=100)
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
    # AI_ANSWER

    There are two UDfs for question answering. The `AI_ANSWER` udf uses some default configuration parameters and a preselected model. If you need more control over your prediction, the `AI_ANSWER_EXTENDED` udf allows you to set all configuration parameters.

    We will start by showing you the `AI_ANSWER` udf.

    Given the same question but two different contexts, we are using the `AI_ANSWER` UDF to extract some answers. In neither case the context has a direct answer to the question. We expect the answer to be relevant to the context.
                                                                                             This udf uses the text-generation pipeline with the [SmolLM2](https://huggingface.co/HuggingFaceTB/SmolLM2-135M-Instruct) model for the prediction. Some of the answer content might be knowledge pulled from the model training data instead of the given context.
    """)
    return

@app.cell
def _(mo):
    editor_004 = mo.ui.code_editor(value='# This will be our question\nTEST_QUESTION = \'What is bitumen used for?\'\n\n# Let\'s first try it with the following context\nTEST_CONTEXT1 = """\nApart from the stylish design features of new flat roofs, the other thing that’s moved on considerably is the technology\nused to keep them weather-proof. Once flat roofs were notoriously prone to leaking and the problem could only be solved\nwith a boiling cauldron of tar. These days there are patch repair kits, liquid rubber membranes, and even quick,\nefficient waterproofing paint that lasts for ages – and can even be applied in damp weather.\n"""\n\n# Make sure our texts can be used in an SQL statement.\nTEST_QUESTION = TEST_QUESTION.replace("\'", "\'\'")\nTEST_CONTEXT1 = TEST_CONTEXT1.replace("\'", "\'\'")', language="python", min_height=100)
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
    The udf takes various input parameters:

    * question: The question text.
    * context_text: The context text, associated with the question.

    You need to supply these parameters in the correct order. Further information can be found in the  <a href="https://github.com/exasol/transformers-extension/blob/main/doc/user_guide/user_guide.md" target="_blank" rel="noopener">User Guide</a>.


    We will save the result in the variable `udf_output` to support automatic testing of this notebook.
    """)
    return

@app.cell
def _(mo):
    editor_005 = mo.ui.code_editor(value="%%sql --save udf_output\nWITH MODEL_OUTPUT AS\n(\n    SELECT AI_ANSWER(\n        '{{TEST_QUESTION}}',\n        '{{TEST_CONTEXT1}}'\n    )\n)\nSELECT answer, error_message FROM MODEL_OUTPUT", language="python", min_height=100)
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
    Let's now change the context and see a different answer.
    """)
    return

@app.cell
def _(mo):
    editor_006 = mo.ui.code_editor(value='# New context\nTEST_CONTEXT2 = """\nYou can make a wooden planter in a day, using treated timber. Simply work out how big an area you need,\ncut the wood to size and follow our steps to putting the planter together. Make sure your wooden planter\nhas drainage holes, so plants don’t become waterlogged.\n"""\n\n# Make sure our text can be used in an SQL statement.\nTEST_CONTEXT2 = TEST_CONTEXT2.replace("\'", "\'\'")', language="python", min_height=100)
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
    editor_007 = mo.ui.code_editor(value="%%sql --save udf_output\nWITH MODEL_OUTPUT AS\n(\n    SELECT AI_ANSWER(\n        '{{TEST_QUESTION}}',\n        '{{TEST_CONTEXT2}}'\n    )\n)\nSELECT answer, error_message FROM MODEL_OUTPUT", language="python", min_height=100)
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
    The code above shows how the model works on a toy example. However, the main purpose of having a model deployed in the database is to get a quick response for a batch input. The performance gain comes from two factors - localization and parallelization. The first means that the input data never crosses the machine boundaries. The second means that multiple instances of the model are processing the data on all available nodes in parallel.

    Another advantage of making predictions within the database is enhanced data security. The task of safeguarding privacy can be simplified given the fact that the source data never leaves the database machine.

    In a more practical application, the question and the context would be stored in columns of a database table. For example, if we wanted to get an answer for each row of the input table `MY_TEXT_TABLE`, where the question is in the column `MY_QUESTION` and the context is in the column `MY_CONTEXT`, the SQL would look similar to this:
    ```
    SELECT AI_ANSWER(MY_QUESTION, MY_CONTEXT) FROM MY_TEXT_TABLE;
    ```
    Please note, that the response time observed on the provided example with a single input will not be scaled up linearly in case of multiple inputs. Much of the latency falls on loading the model into the CPU memory from BucketFS. This needs to be done only once regardless of the number of inputs.

    # AI_ANSWER_EXTENDED

    If you want to use a different model for prediction, you can use the `AI_ANSWER_EXTENDED` udf instead. This will work nearly the same, but you need to have a model installed and then set the udf parameters so the model can be found by the udf.
    """)
    return

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    ## Get a language model

    To demonstrate the question-answering with the text-generation task, we will use the [Qwen/Qwen2.5-0.5B-Instruct](https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct) model.

    We need to load the model from the Hugging Face Hub into the [BucketFS](https://docs.exasol.com/db/latest/database_concepts/bucketfs/bucketfs.htm). This could potentially be a long process, depending on the speed of the database connection. Unfortunately, we cannot tell exactly when it has finished. The notebook's hourglass may not be a reliable indicator. BucketFS will still be doing some work when the call issued by the notebook returns. Please wait for a few moments after that, before querying the model.

    You might see a warning that some weights are newly initialized and the model should be trained on a down-stream task. Please ignore this warning. For the purpose of this demonstration, it is not important, the model should still be able to produce some meaningful output.
    """)
    return

@app.cell
def _(mo):
    editor_008 = mo.ui.code_editor(value="from exasol.nb_connector.model_installation import install_model, TransformerModel\nfrom transformers import AutoModelForCausalLM\n\n# This is the name of the model at the Hugging Face Hub\nMODEL_NAME = 'Qwen/Qwen2.5-0.5B-Instruct'\ninstall_model(ai_lab_config, TransformerModel(MODEL_NAME, 'text-generation', AutoModelForCausalLM))", language="python", min_height=100)
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
    ## Use the language model

    We are going to check the model output given the same question and contexts as before, but this time using the `AI_ANSWER_EXTENDED` UDF. 

    The udf takes various input parameters:

    * device_id: To run the UDF on a GPU, specify the valid cuda device ID.
    * bucketfs_conn: The BucketFS connection name.
    * sub_dir: The directory where the model is stored in the BucketFS.
    * model_name: The name of the model to use for prediction.
    * question: The question text.
    * context_text: The context text, associated with the question.

    You need to supply these parameters in the correct order. Further information can be found in the  <a href="https://github.com/exasol/transformers-extension/blob/main/doc/user_guide/user_guide.md" target="_blank" rel="noopener">User Guide</a>.


    We will save the result in the variable `udf_output` to support automatic testing of this notebook.
    """)
    return

@app.cell
def _(mo):
    editor_009 = mo.ui.code_editor(value="%%sql --save udf_output\nWITH MODEL_OUTPUT AS\n(\n    SELECT AI_ANSWER_EXTENDED(\n        NULL,\n        '{{ai_lab_config.bfs_connection_name}}',\n        '{{ai_lab_config.bfs_model_subdir}}',\n        '{{MODEL_NAME}}',\n        '{{TEST_QUESTION}}',\n        '{{TEST_CONTEXT1}}'\n    )\n)\nSELECT answer, error_message FROM MODEL_OUTPUT", language="python", min_height=100)
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
    Let's now use the second context and see a different answer.
    """)
    return

@app.cell
def _(mo):
    editor_010 = mo.ui.code_editor(value="%%sql --save udf_output\nWITH MODEL_OUTPUT AS\n(\n    SELECT AI_ANSWER_EXTENDED(\n        NULL,\n        '{{ai_lab_config.bfs_connection_name}}',\n        '{{ai_lab_config.bfs_model_subdir}}',\n        '{{MODEL_NAME}}',\n        '{{TEST_QUESTION}}',\n        '{{TEST_CONTEXT2}}'\n    )\n)\nSELECT answer, error_message FROM MODEL_OUTPUT", language="python", min_height=100)
    run_010 = mo.ui.run_button(label="Run cell 10")
    mo.vstack([editor_010, run_010])
    return editor_010, run_010

@app.cell
def _(editor_010, lesson, mo, render, run_010):
    mo.stop(not run_010.value)
    render(mo, lesson.run(editor_010.value))
    return

if __name__ == "__main__":
    app.run()
