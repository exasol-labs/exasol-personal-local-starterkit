# FAQ (/data-scientist/faq)



<Accordions type="multiple">
  <Accordion title="Do I need a terminal?">
    No. Everything the notebooks need runs from a cell or a card: `nb.kit_check()`, `nb.exakit(...)`, `nb.addon_ready(...)`. See [Run the kit from a notebook](/data-scientist/guides/run-the-kit).
  </Accordion>

  <Accordion title="Do I need an AI model?">
    No. Every step runs without one. A model is used only to draft SQL in Ask and to sort texts into themes, and both are off until you turn them on. Ask also has a drafter with no model: `nb.draft_question`.
  </Accordion>

  <Accordion title="Is my data sent anywhere?">
    Not by default. The database and the notebooks run on this computer. With a model set up, Ask sends the column map and your question, never rows. The themes step sends a sample of texts, and asks first when the data is a live external source.
  </Accordion>

  <Accordion title="What is a descriptor?">
    The column map: the role of every column in a table. See [Descriptor and approval](/data-scientist/concepts/descriptor).
  </Accordion>

  <Accordion title="Who is the approver?">
    You are. The kit proposes roles; a person approves them. A model never approves, and the kit never chooses the target.
  </Accordion>

  <Accordion title="Why does a notebook say my data is not approved?">
    Explore, Ask and Share read only an approved column map. Open `00_quickstart`, review the map and approve it. See [Review and approve the column map](/data-scientist/guides/approve-column-map).
  </Accordion>

  <Accordion title="How do I switch to another dataset?">
    Approve it in the quickstart. With `DATASET = None`, the other notebooks follow the dataset approved last when you run their first cell again. Or set `DATASET = "..."` in a notebook to pin one.
  </Accordion>

  <Accordion title="Can I use my own table?">
    Yes. Load a file with `nb.load_own_file(...)`, or use a table already in the database with `nb.use_table(...)`. See [Load data](/data-scientist/guides/load-data).
  </Accordion>

  <Accordion title="Does preparing the data change my table?">
    No. The checks only read. The joined view and the typed view are views in `EXAKIT_PREPARED`, created only when you ask.
  </Accordion>

  <Accordion title="Can an AI-drafted query change my data?">
    No. Nothing runs until you approve the exact text, and approved questions run as the read-only user.
  </Accordion>

  <Accordion title="Where is my work saved?">
    Under `~/.exasol-starter-kit`: column maps, workflow logs and hand-off bundles. See [Where things live](/data-scientist/develop/where-things-live).
  </Accordion>

  <Accordion title="Will an update overwrite my notebooks?">
    No. A notebook you edited is never overwritten, and one you deleted is not copied back.
  </Accordion>

  <Accordion title="JupyterLab or Marimo?">
    Either. The same notebooks ship for both. `exakit notebook` opens JupyterLab and `exakit notebook marimo` opens Marimo.
  </Accordion>

  <Accordion title="How do I find a command?">
    `nb.docs("words")` searches these docs, and `nb.docs(nb.some_command)` opens that command's page. [All commands](/data-scientist/reference) lists every one.
  </Accordion>
</Accordions>
