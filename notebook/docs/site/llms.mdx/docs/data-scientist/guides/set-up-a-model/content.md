# Set up a model (/data-scientist/guides/set-up-a-model)



A model is optional. It is used to draft SQL in Ask and to sort texts into themes in Explore. Any endpoint that speaks the Chat Completions API works: an external provider or a model on your own machine.

## The quickest way [#the-quickest-way]

```python
nb.model_setup()
```

It asks for anything missing, with the keys in a hidden box, says what is set, and prints the lines that set the same thing for every notebook.

## In a cell [#in-a-cell]

```python
nb.use_model("your-model-id", "https://your-provider/v1/")                     # this kernel only
nb.use_model("your-model-id", "https://your-provider/v1/", remember=True)      # every notebook of this kit
nb.use_model(langfuse_base_url="https://cloud.langfuse.com", remember=True)    # tracing
```

The API key is asked in a hidden box. With `remember=True` it is kept in the kit's credentials, readable by you only.

## Check and forget [#check-and-forget]

```python
nb.model_settings()                            # what is set, without secrets
nb.tracing()                                   # is Langfuse tracing on?
nb.forget_model(model=True, langfuse=True)     # delete what was remembered
```

## The settings behind it [#the-settings-behind-it]

| Setting                                                           | What it is             |
| ----------------------------------------------------------------- | ---------------------- |
| `EXAKIT_MODEL_ID`                                                 | The model's id         |
| `EXAKIT_PROVIDER_BASE_URL`                                        | The endpoint's address |
| `EXAKIT_PROVIDER_API_KEY`                                         | The key                |
| `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY`, `LANGFUSE_BASE_URL` | Turn tracing on        |

The model's id and address can also live in `~/.exasol-starter-kit/exakit.env`. Provider recipes are in `MODEL-PROVIDERS.md`, copied beside the notebooks.

<Callout type="warn">
  Never type a key into a cell. Use the hidden box, so the key is not saved in the notebook file.
</Callout>
