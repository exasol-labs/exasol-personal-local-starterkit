# Is my data sent anywhere? (/data-scientist/explore/data-privacy)



Not by default. The database and the notebooks run on this computer. A step sends data to an AI model only when you set up a model and turn the step on. The steps below say what each one sends.

## Is my data sent anywhere? [#is-my-data-sent-anywhere]

Not by default. The database and the notebooks run on this computer.

* With no model set up, every step runs on this computer. The rules drafter for Ask sends nothing.
* With a model set up, Ask sends the approved column map and your question. It never sends rows.
* The themes step sends a sample of texts, and it is off until you turn it on. It is in `01_explore`: set `USE_AI_THEMES = True` in the first cell, with a model set up. Your model then sorts the newest texts where the target is 1 and where it is 0 into themes. It makes two model calls.
* A table from a live external source asks before any sampled rows go to a model.
* The semantic model's AI proposal receives names, types, grains, column notes and a category's most frequent values. It never receives a row, and never a sensitive column. See [Semantic views](/data-scientist/explore/semantic-views#the-ai-proposes-the-fields).

Sensitive columns are never sent to a model. See [The column map](/data-scientist/explore/column-map) for how the kit marks them.

Back to [Explore and understand](/data-scientist/explore). Previous: [Ask questions in plain language](/data-scientist/explore/questions). Next: [When it goes wrong](/data-scientist/explore/troubleshooting).
