# Starter Kit documentation (/)



Each persona of the kit has its own notebooks and its own section here. Pick yours below, or in the list at the top of the sidebar.

<Cards>
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
