# Basic EvalHub on Red Hat AI

A hands-on showroom workshop for evaluation-driven LLM operations on Red Hat OpenShift AI 3.5 using **EvalHub** and **MLflow**.

Participants learn why stochastic LLMs need systematic evaluation gates, run performance and accuracy jobs through EvalHub (without wiring each evaluator SDK in isolation), unify results under shared MLflow experiments, and evaluate content-safety guardrails.

Hands-on notebooks live in the companion lab: [hyogrin/rhoai-evalhub-lab](https://github.com/hyogrin/rhoai-evalhub-lab).

## Local preview

```bash
chmod +x scripts/preview-local.sh
./scripts/preview-local.sh            # live preview (podman → docker → npm)
./scripts/preview-local.sh build      # static site → ./docs
./scripts/preview-local.sh serve      # serve ./docs on :8080
./scripts/preview-local.sh stop       # stop preview container
```

## Screenshots

Module pages reference placeholder images under `content/modules/ROOT/assets/images/`.
Capture the real UI, then overwrite the file with the **same name** listed in
[`content/modules/ROOT/assets/images/SCREENSHOTS.md`](content/modules/ROOT/assets/images/SCREENSHOTS.md)
— no AsciiDoc edits needed.

See [README.adoc](README.adoc) for more local development details.
