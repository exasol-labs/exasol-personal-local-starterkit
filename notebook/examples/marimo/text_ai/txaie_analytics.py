import marimo

__generated_with = "0.25.2"
app = marimo.App()

@app.cell
def _():
    import marimo as mo
    from exakit.nb.example_runtime import Lesson, render
    lesson = Lesson('text_ai/txaie_analytics.ipynb')
    return lesson, mo, render

@app.cell(hide_code=True)
def _(mo):
    mo.md("""
    # Bundled Exasol lesson: Data Analysis with Text AI

    Requires a configured Text AI Extension and its database objects. These services are not installed by opening a notebook.

    Run cells from top to bottom. In Marimo each editable cell has its own Run button; opening a lesson executes no example code. Widget steps retain their Python code; use the matching Jupyter notebook for the original widget UI.

    For dashboards use the kit Data Scientist 03_share flow on Dash Server.

    Source: [Exasol Notebook Connector](https://github.com/exasol/notebook-connector/blob/14e2c7ad088b7109aa21d283e98f3126bbbe27e5/exasol/nb_connector/resources/notebooks/text_ai/txaie_analytics.ipynb). MIT license: LICENSE.txt.
    """)
    return

@app.cell
def _(mo):
    editor_001 = mo.ui.code_editor(value="from exakit.nb.example_runtime import bootstrap\nai_lab_config = bootstrap(globals(), 'text_ai/txaie_analytics.ipynb')", language="python", min_height=100)
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

    # Data Analysis with Text AI

    In this notebook, we will do some basic analysis on the semantic data extracted from the Customer Support Tickets.

    We will be running SQL queries using both the <a href="https://github.com/ploomber/jupysql" target="_blank" rel="noopener">JupySQL</a>SQL Magic
    and the <a href="https://github.com/exasol/pyexasol" target="_blank" rel="noopener">`pyexasol`</a>.

    ## Prerequisites

    Prior to using this notebook the following step needs to be completed:
    1. [Run Text AI Preprocessing](/?file=exasol-examples/text_ai/txaie_preprocessing.py).

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
    ### Initialise JupySQL
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
    ### Import Python modules
    """)
    return

@app.cell
def _(mo):
    editor_004 = mo.ui.code_editor(value='import pandas as pd\nfrom ipywidgets import Dropdown\nimport matplotlib.pyplot as plt\nfrom wordcloud import WordCloud\nfrom exakit.nb.example_runtime import open_pyexasol_connection', language="python", min_height=100)
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
    ## Urgent vs Non-urgent tieckts

    ### Create `TICKET_URGENCY` view

    First, let us create a view that adds the `IS_URGENT` flag to each document. For this, we can use the results of the topic classifier. We have run the classifier using two topics - "urgent" and "not urgent". The output of the classifier is the cross product of the documents (tickets) and topics. For our purpose we can select the rows with the "urgent" topic.

    For each document, the classifier sets the rank and the score of every topic. We do not want to rely purely on the rank, because it does not indicate certainty of the classification. Instead we will use the score which is akin a probability of the document belonging to the given topic (assuming the topics are mutually exclusive). We will deem the ticket as urgent if its "urgent" topic score is greater than 0.7.
    """)
    return

@app.cell
def _(mo):
    editor_005 = mo.ui.code_editor(value="%%sql\nCREATE OR REPLACE VIEW TICKET_URGENCY AS\nSELECT \n    D.*,\n    T.TOPIC_SCORE,\n    T.TOPIC_SCORE > 0.7 AS IS_URGENT\nFROM DOCUMENTS_AI_LAB_CUSTOMER_SUPPORT_TICKETS_VIEW_VIEW D\nJOIN TOPICS_VIEW T ON \n    D.TEXT_DOC_ID=T.TEXT_DOC_ID AND \n    D.TEXT_CHAR_BEGIN=T.TEXT_CHAR_BEGIN AND\n    D.TEXT_CHAR_END=T.TEXT_CHAR_END\nWHERE T.TOPIC='urgent'", language="python", min_height=100)
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
    Now we can inspect the urgent tickets. 

    **Note**: We will often see tickets that contain phrases, like "I need them urgently", or "but the issue remains unresolved". These prhases indicate for the model a higher urgency of a ticket. However, this might only reflect the urgency for the author of the ticket and are soley based on the content of ticket description. The extracted urgency might not reflect your internal work priority for tickets. Also, for the classification of the ticket priority, factors that are external to the text might need to be considered. The model here can only consider the information conveyed by the text which might be able to give input for the final classification of the ticket priority.
    """)
    return

@app.cell
def _(mo):
    editor_006 = mo.ui.code_editor(value='%%sql\nSELECT TICKET_ID, CUSTOMER_NAME, DATE_OF_PURCHASE, TICKET_DESCRIPTION, TOPIC_SCORE\nFROM TICKET_URGENCY\nWHERE IS_URGENT = TRUE', language="python", min_height=100)
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
    ### Count urgent and non-urgent tickets

    Here we will display the total number of urgent and non-urgent tickets.
    """)
    return

@app.cell
def _(mo):
    editor_007 = mo.ui.code_editor(value="%%sql --save URGENT_TICKET_COUNT\nSELECT 'Urgent' as URGENCY, SUM(IS_URGENT) AS CNT\nFROM TICKET_URGENCY\nUNION\nSELECT 'Not Urgent' as URGENCY, SUM(1 - IS_URGENT) AS CNT\nFROM TICKET_URGENCY\nORDER BY 1", language="python", min_height=100)
    run_007 = mo.ui.run_button(label="Run cell 7")
    mo.vstack([editor_007, run_007])
    return editor_007, run_007

@app.cell
def _(editor_007, lesson, mo, render, run_007):
    mo.stop(not run_007.value)
    render(mo, lesson.run(editor_007.value))
    return

@app.cell
def _(mo):
    editor_008 = mo.ui.code_editor(value='%sqlplot pie --table URGENT_TICKET_COUNT --column URGENCY CNT', language="python", min_height=100)
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
    ## Products with urgent tickets

    In this section we will take a look at which products have the biggest number of urgent tickets.

    ### Inspecting the Products

    Let us first inspect the products that were extracted from the tickets

    We will use the results of the named entity extractor. The products are entities where the `entity_type` looks like "product_xxx". Note, that the extractor also provides the positions of entities in the text, which we don't need here. We shall account for the fact that there are potentially multiple instances of the same entity in a document.
    """)
    return

@app.cell
def _(mo):
    editor_009 = mo.ui.code_editor(value="%%sql products_with_ticket_count <<\nSELECT E.ENTITY as PRODUCT, COUNT(DISTINCT D.TICKET_ID) as TICKET_COUNT\nFROM DOCUMENTS_AI_LAB_CUSTOMER_SUPPORT_TICKETS_VIEW_VIEW D\nJOIN NAMED_ENTITY_VIEW E ON \n    D.TEXT_DOC_ID=E.TEXT_DOC_ID AND \n    D.TEXT_CHAR_BEGIN=E.TEXT_CHAR_BEGIN AND\n    D.TEXT_CHAR_END=E.TEXT_CHAR_END\nWHERE E.ENTITY_TYPE like 'product%'\nGROUP BY E.ENTITY\nORDER BY TICKET_COUNT DESC", language="python", min_height=100)
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
    Now lets show the products in a word cloud. The font size of the product is larger for products that occur in more tickets. The colors in the word cloud are choosen to easier distingish different words.
    """)
    return

@app.cell
def _(mo):
    editor_010 = mo.ui.code_editor(value='products_with_ticket_count_df = products_with_ticket_count.DataFrame()\nproducts_with_ticket_count_dict = products_with_ticket_count_df.set_index("product")["ticket_count"].to_dict()\nwordcloud = WordCloud(background_color="white").generate_from_frequencies(products_with_ticket_count_dict)\nplt.imshow(wordcloud, interpolation=\'bilinear\')\nplt.axis("off")\nplt.show()', language="python", min_height=100)
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
    ### Create `PRODUCT_ATTENTION` view

    From this point onward we will be looking at a limited number of products with the biggest number of urgent tickets. Let us first create a view `URGENT_PRODUCT_CO_OCCURRENCE` that selects products that are contained inside extracted topic with the label `urgent`.

    To create `URGENT_PRODUCT_CO_OCCURRENCE` view we are using the `CO_OCCURRENCE` view which is created by the `StandardExtractor`. The `CO_OCCURRENCE` view joins topics, named entities and keywords in the same document together and provides addtional columns to define the positional relations between them, such as the distance between an named entity and a keyword. However, for the moment we don not need these relations
    """)
    return

@app.cell
def _(mo):
    editor_011 = mo.ui.code_editor(value="%%sql\nCREATE OR REPLACE VIEW URGENT_PRODUCT_CO_OCCURRENCE AS\nSELECT *\nFROM CO_OCCURRENCE COO\nWHERE TOPIC = 'urgent'\nAND ENTITY_TYPE like 'product%'", language="python", min_height=100)
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
    Now we can create a view `PRODUCT_ATTENTION` on top of `URGENT_PRODUCT_CO_OCCURRENCE`, that selects the ten products with the most urgent tickets.
    """)
    return

@app.cell
def _(mo):
    editor_012 = mo.ui.code_editor(value='%%sql\nCREATE OR REPLACE VIEW PRODUCT_ATTENTION AS\nSELECT COO.ENTITY AS PRODUCT, COUNT(DISTINCT D.TICKET_ID) as URGENT_TICKETS\nFROM URGENT_PRODUCT_CO_OCCURRENCE COO\nJOIN DOCUMENTS_AI_LAB_CUSTOMER_SUPPORT_TICKETS_VIEW_VIEW AS D\nON D.text_doc_id = COO.text_doc_id\nWHERE COO.TOPIC_SCORE > 0.7\nGROUP BY local.PRODUCT\nORDER BY local.URGENT_TICKETS DESC\nLIMIT 10', language="python", min_height=100)
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
    ### Show the number of tickets for the selected products

    Here we will look at the number of urgent and non-urgent tickets for each of the selected products.
    """)
    return

@app.cell
def _(mo):
    editor_013 = mo.ui.code_editor(value='%%sql\nCREATE OR REPLACE VIEW TICKET_URGENCY_FOR_PRODUCTS_UNDER_ATTENTION AS\nSELECT DISTINCT TICKET_ID, ENTITY AS PRODUCT, TOPIC_SCORE > 0.7 as IS_URGENT\nFROM URGENT_PRODUCT_CO_OCCURRENCE COO\nJOIN DOCUMENTS_AI_LAB_CUSTOMER_SUPPORT_TICKETS_VIEW_VIEW AS D\nON D.text_doc_id = COO.text_doc_id\nJOIN PRODUCT_ATTENTION A \nON COO.ENTITY=A.PRODUCT', language="python", min_height=100)
    run_013 = mo.ui.run_button(label="Run cell 13")
    mo.vstack([editor_013, run_013])
    return editor_013, run_013

@app.cell
def _(editor_013, lesson, mo, render, run_013):
    mo.stop(not run_013.value)
    render(mo, lesson.run(editor_013.value))
    return

@app.cell
def _(mo):
    editor_014 = mo.ui.code_editor(value='%%sql\nSELECT PRODUCT, SUM(IS_URGENT) as IS_URGENT\nFROM TICKET_URGENCY_FOR_PRODUCTS_UNDER_ATTENTION\nGROUP BY PRODUCT\nORDER BY IS_URGENT DESC', language="python", min_height=100)
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
    Now let us compute the percentage of urgent and non-urgent tickets for each of the selected products and plot it as a bar chart.
    """)
    return

@app.cell
def _(mo):
    editor_015 = mo.ui.code_editor(value='%%sql precent_of_urgent_tickets_per_product <<\nSELECT PRODUCT, SUM(1-IS_URGENT)/COUNT(1)*100 as IS_NOT_URGENT, SUM(IS_URGENT)/COUNT(1)*100 as IS_URGENT\nFROM TICKET_URGENCY_FOR_PRODUCTS_UNDER_ATTENTION\nGROUP BY PRODUCT\nORDER BY IS_URGENT ASC', language="python", min_height=100)
    run_015 = mo.ui.run_button(label="Run cell 15")
    mo.vstack([editor_015, run_015])
    return editor_015, run_015

@app.cell
def _(editor_015, lesson, mo, render, run_015):
    mo.stop(not run_015.value)
    render(mo, lesson.run(editor_015.value))
    return

@app.cell
def _(mo):
    editor_016 = mo.ui.code_editor(value='precent_of_urgent_tickets_per_product.DataFrame().set_index("product").plot(kind=\'barh\', stacked=True, xlabel="percent of tickets")', language="python", min_height=100)
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
    ## Reasons behind tickets

    In this section we will try to look at common reasons for raising a ticket, in a scope of a particular product. The reasons or clues, as it might be a better term, are represented by keywords. 

    First we will load out selected products into a dropdown box.
    """)
    return

@app.cell
def _(mo):
    editor_017 = mo.ui.code_editor(value='query = """\nSELECT PRODUCT\nFROM PRODUCT_ATTENTION\nORDER BY URGENT_TICKETS DESC\n"""\n\nwith open_pyexasol_connection(ai_lab_config, compression=True, schema=ai_lab_config.db_schema) as connection:\n    options = connection.execute(query=query).fetchcol()\n\ndropdown = Dropdown(\n    options=options,\n    style={\'description_width\': \'initial\'}\n)\ndisplay(dropdown)', language="python", min_height=100)
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
    ### View keywords in a Word Cloud

    We will compute frequencies of the keywords in the tickets for the selected product. There are few keywords we would want to exclude. Firstly, this is the name of the product or any part of the name. Then we also want to exclude some common words which, unfortunately are often identified as keywords. Below is the list of such common words. It can be extended as appropriate.
    """)
    return

@app.cell
def _(mo):
    editor_018 = mo.ui.code_editor(value='exclude_keywords = "(\'product\', \'issue\')"', language="python", min_height=100)
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
    Now we are ready to compute and display the keyword frequencies. 

    We will use the sum of the keyword scores as a proxy for the frequency. The score is akin a probability that the word is actually a keyword. So, the sum of the scores can be interpreted as an expectation of the total number of occurrences of the given keyword in the collection of tickets for the selected product.
                                                                                                                                                                Note, that the keyword extractor output includes the positions of keywords in the text. These positions themselves are not required for our analysis. However, the implication is that a document may have multiple instances of the same keyword. For the sake of simplicity, we compute the frequency not limiting the number of occurrences of a keyword in a single document to one.                                                                                                                               
    We will reuse our `URGENT_PRODUCT_CO_OCCURRENCE` view from before. We only add addtional conditions and aggregate the data as described.
    """)
    return

@app.cell
def _(mo):
    editor_019 = mo.ui.code_editor(value="%%sql product_keywords_with_scores <<\nSELECT\n    COO.ENTITY as PRODUCT,\n    COO.KEYWORD,\n    SUM(COO.KEYWORD_SCORE) AS SCORE\nFROM URGENT_PRODUCT_CO_OCCURRENCE COO\nWHERE COO.ENTITY='{{dropdown.value}}'\nAND INSTR('{{dropdown.value.strip().upper()}}', UCASE(COO.KEYWORD)) = 0\nAND COO.KEYWORD NOT IN {{exclude_keywords}}\nGROUP BY COO.ENTITY, COO.KEYWORD\nORDER BY SCORE DESC", language="python", min_height=100)
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
    We will plot the the keywords in a word cloud. The font-size will be larger for keywords that have a higher sum of scores.
    """)
    return

@app.cell
def _(mo):
    editor_020 = mo.ui.code_editor(value='keywords_with_scores = product_keywords_with_scores.DataFrame()[["keyword", "score"]]\nkeywords_with_scores_dict = keywords_with_scores.set_index("keyword")["score"].to_dict()\nwordcloud = WordCloud(background_color="white").generate_from_frequencies(keywords_with_scores_dict)\nplt.imshow(wordcloud, interpolation=\'bilinear\')\nplt.axis("off")\nplt.show()', language="python", min_height=100)
    run_020 = mo.ui.run_button(label="Run cell 20")
    mo.vstack([editor_020, run_020])
    return editor_020, run_020

@app.cell
def _(editor_020, lesson, mo, render, run_020):
    mo.stop(not run_020.value)
    render(mo, lesson.run(editor_020.value))
    return

if __name__ == "__main__":
    app.run()
