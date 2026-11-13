# Rare answers (/data-scientist/evaluate/rare-answers)



When one answer is rare, a model can look good by always giving the common answer. This page shows the numbers from the two sample datasets, and what the kit does about it.

## Why accuracy misleads [#why-accuracy-misleads]

`fraud_transactions` has 51,000 rows, and 2,510 of them are fraud (4.9%). A model that always says "not fraud" is right on 48,490 rows, which is about 95% accuracy. It finds no fraud at all. A score that rewards that model is useless for finding fraud.

The data check reports the same thing. `nb.data_checks` prints a finding named "rare label", and the sentence says what a model that always answers the common value achieves.

## Two thresholds, for two different jobs [#two-thresholds-for-two-different-jobs]

The kit uses two cut-offs for the share of the rarer answer. They do different jobs, so the numbers differ.

| Where                                     | Threshold | What happens                                  | `amazon_sales` (14.2%) | `fraud_transactions` (4.9%) |
| ----------------------------------------- | --------- | --------------------------------------------- | ---------------------- | --------------------------- |
| `nb.data_checks` (the rare-label finding) | Under 10% | The label is reported as rare                 | Not reported           | Reported as rare            |
| The model lab                             | Under 5%  | The lab scores with PR AUC instead of ROC AUC | ROC AUC                | PR AUC                      |

## What PR AUC is [#what-pr-auc-is]

PR AUC is the average precision score. It ranks the rows by the model's score and asks how many of the rows at the top are real 1s, averaged over the ranking. It is only interested in finding the 1s, so it does not reward a model for being right about the many 0s. The lab records the reason in `lab.run.notes`: "The 1s are rare, so the score is PR AUC, which focuses on finding them."

## What the readout note says [#what-the-readout-note-says]

For ROC AUC, `nb.note_model` names the always-common guess and its accuracy as the baseline to beat. The note also says that accuracy is not the score when the answer is rare.

## Repeated rows can also inflate a rare-answer score [#repeated-rows-can-also-inflate-a-rare-answer-score]

`fraud_transactions` has 51,000 rows and 50,000 distinct `TRANSACTION_ID` values. So 1,000 ids appear twice. When a repeated copy lands on both sides of the split, the model can score a row it has already learned. `nb.data_checks` reports repeated ids and exact copies. Read that report before you judge a score on this table. The split is on [Hold-out](/data-scientist/evaluate/hold-out).

Back to [Evaluate](/data-scientist/evaluate). Next: [Leakage](/data-scientist/evaluate/leakage).
