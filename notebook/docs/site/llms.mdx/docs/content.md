# Starter Kit documentation (/)



The kit puts an Exasol database on this computer and sets it up for the work you do. What it sets up depends on your **persona**. Pick a section below, or in the list at the top of the sidebar.

<Cards>
  <Card title="All personas" href="/kit">
    The kit itself: what a persona is, loading data, column maps, add-ons and every command.
  </Card>

  <Card title="Data Scientist" href="/data-scientist">
    Four notebooks and nine steps: load data, agree what each column means, explore, model, ask questions and share.
  </Card>
</Cards>

## From a notebook [#from-a-notebook]

```python
import exakit.nb as nb

nb.docs()                  # your persona's section, under the cell
nb.docs("descriptor")      # search
nb.docs(nb.describe)       # one command's page
```

`nb.docs()` opens the section of the persona whose notebook you are in.
