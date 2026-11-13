# Deploying a model (/data-scientist/communicate/deploying-a-model)



## Deploying a model [#deploying-a-model]

The kit does not deploy a model from these notebooks.

* The lab's fitted model is kept only in your kernel. Nothing saves or serves it. See [Saving, MLflow and training in the database](/data-scientist/model/saving-and-mlflow).
* `nb.use_model` and `nb.forget_model` look like they are about a model, but they are about the AI model endpoint and the Langfuse keys. They do not save or delete a trained model.
* Scoring a model inside the database is the ML Engineer's path. It needs the udf-devkit add-on (`exakit marketplace udf-devkit`), which provides a Python container for training and scoring.
* `exakit model put <file>` copies a model file into the bucket folder that the database's functions read, and `exakit model list` shows what is there. `nb.model_list()` returns the same list in a notebook.
* The ML Engineer's training runs `nb.prepare_training`, which is described on the [model page](/data-scientist/model/saving-and-mlflow). It writes the coefficients of a trained logistic regression beside the training hand-off, so a scoring notebook can read them without MLflow.

If you need a model in production, that path is the one the kit has. The Data Scientist notebooks stop at the result, the dashboard and the hand-off.

Back to [Communicate and deploy](/data-scientist/communicate).
