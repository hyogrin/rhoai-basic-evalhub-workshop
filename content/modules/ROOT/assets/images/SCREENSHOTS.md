# Screenshot capture checklist

Replace each **placeholder** PNG in this folder with a real capture using the **exact same filename**. No AsciiDoc edits required after that — rebuild/preview to see the new image.

| File | Module | What to capture |
|------|--------|-----------------|
| `img-evalhub-architecture.png` | 01 Intro | Diagram or UI showing EvalHub orchestrating providers → MLflow |
| `img-eval-dimensions.png` | 01 Intro | Optional visual for performance / accuracy / safety dimensions |
| `img-setup-workbench-clone.png` | 02 Setup | Workbench terminal after `git clone` of `rhoai-evalhub-lab` |
| `img-setup-env-configured.png` | 02 Setup | Notebook Step 0 printout (`NAMESPACE`, `EVALHUB_URL`, model vars) |
| `img-setup-evalhub-providers.png` | 02 Setup | Successful `providers.list()` / connectivity output |
| `img-setup-mlflow-experiments.png` | 02 Setup | RHOAI Dashboard → MLflow **Experiments** list |
| `img-guidellm-notebook-job.png` | 03 GuideLLM | Notebook: GuideLLM job id + completed state |
| `img-guidellm-mlflow-experiment.png` | 03 GuideLLM | MLflow: select `guidellm-*` experiment |
| `img-guidellm-mlflow-metrics.png` | 03 GuideLLM | MLflow run metrics (TTFT / throughput / latency) |
| `img-kmcq-notebook-job.png` | 04 Korean MCQ | Notebook: job submit + MLflow experiment id |
| `img-kmcq-mlflow-metrics.png` | 04 Korean MCQ | MLflow accuracy metrics for HAE-RAE / KMMLU run |
| `img-kmcq-summary-report.png` | 04 Korean MCQ | HTML/Markdown summary table from summarize notebook |
| `img-unified-notebook-experiment.png` | 05 Unified | Notebook printing shared `EXPERIMENT_NAME` |
| `img-unified-mlflow-runs.png` | 05 Unified | MLflow: multiple runs under one experiment |
| `img-unified-mlflow-compare.png` | 05 Unified | MLflow compare view (accuracy + performance) |
| `img-guardrail-regex-vs-safety.png` | 06 Guardrails | Notebook: regex-only vs content-safety outcomes |
| `img-guardrail-report-overview.png` | 06 Guardrails | HTML report overview (precision / recall / F1) |
| `img-guardrail-confusion-matrix.png` | 06 Guardrails | Confusion matrix from the guardrail report |

**Tips**

- Prefer 1280×720 or wider; crop UI chrome that is not relevant.
- Avoid secrets (API keys, tokens) in screenshots.
- After replacing files: `./scripts/preview-local.sh build` (or live preview).
