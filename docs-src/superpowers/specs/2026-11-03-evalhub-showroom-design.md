# Basic EvalHub Workshop Showroom — Design

**Date:** 2026-11-03  
**Status:** Approved for implementation

## Goal

Create an Antora/RHDP showroom at the **repo root**, patterned after `rhoai-basic-agentops-workshop`, that teaches evaluation-driven LLM ops with **EvalHub** + **MLflow**. Hands-on work runs notebooks from the separate lab repo [`hyogrin/rhoai-evalhub-lab`](https://github.com/hyogrin/rhoai-evalhub-lab); the showroom explains concepts, key SDK snippets, and how to verify results in MLflow.

## Decisions

| Topic | Choice |
|-------|--------|
| Scope | Core EvalHub + Guardrails (no DS Pipeline module) |
| Language | English AsciiDoc |
| Layout | Showroom at repo root; nested `rhoai-basic-agentops-workshop/` and `rhoai-evalhub-lab/` are temporary references and will be removed |
| Notebook links | Workbench path after clone **and** GitHub blob URL |
| Pedagogy | AgentOps-style module pages: why → Run All notebook → snippet → verify in MLflow/report |

## Module map

1. Introduction — stochastic LLMs, evaluation-driven approach, EvalHub role  
2. Setup — `0_setup/1_eval_hub_setup.ipynb`  
3. GuideLLM performance — `1_eval_hub_guidellm_benchmark/1_guidellm_benchmark.ipynb`  
4. Korean MCQ accuracy — `2_eval_hub_kmcq_benchmark/1_kmcq_benchmark.ipynb`  
5. Unified evaluation — `3_eval_hub_unified_benchmark/1_unified_benchmark.ipynb`  
6. Guardrails evaluation — `5_eval_guardrail/*`  
7. Closing  

## Hands-on page pattern

1. Learning objectives + short concept  
2. Open notebook (local path + GitHub) → Run All  
3. Code snippet(s) for EvalHub SDK / config essence  
4. Verify in MLflow UI / HTML report  

## Out of scope

- Rewriting lab notebooks  
- Data Science Pipeline module (`4_eval_pipeline`)  
- Publishing nested reference folders as Antora content  
