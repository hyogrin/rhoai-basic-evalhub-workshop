# Workshop environment: changes and findings

| | |
|---|---|
| **Environment** | RHDP sandbox `m8hk2` (`api.ocp.m8hk2.sandbox697.opentlc.com`), OCP 4.22, RHOAI 3.5.3, RHCL 1.4.3 |
| **Date** | 2026-11-17 |
| **Setup scripts** | `rhoai-field-source-setup-guide/scripts/field-source-enable-all-features-35.sh`, `field-source-setup-maas-35.sh` |

This file lists every cluster change made during the workshop and every problem found. Detailed write-ups are linked where they exist.

| # | Item | Type | Applied on `m8hk2` | In setup script |
|---|---|---|---|---|
| 1 | RHCL / Kuadrant operator memory patch | Fix | Yes | **No.** Still a manual step |
| 2 | GPU ClusterPolicy: DCGM exporter ServiceMonitor | Fix | Yes | Yes (`field-source-enable-all-features-35.sh`) |
| 3 | Worker node and GPU capacity | Capacity finding | No change made | No |
| 4 | Participant-side issues (user20, user9) | Findings | No change made | Not applicable |

---

## 1. RHCL patch: Kuadrant operator OOMKilled

**Full RCA:** [rca-maas-subscriptions-degraded-kuadrant-oom.md](rca-maas-subscriptions-degraded-kuadrant-oom.md)

- **Problem:** `kuadrant-operator-controller-manager` was in CrashLoopBackOff with `OOMKilled` because of the default **300Mi** memory limit. New `TokenRateLimitPolicy` objects never got a status, so MaaS subscriptions showed **Degraded**, auth policies stayed **Pending**, and model refs stayed **Pending**.
- **Change:** raised the operator's resources through the OLM Subscription:
  ```bash
  oc patch subscriptions.operators.coreos.com rhcl-operator \
    -n redhat-connectivity-link-operator --type=merge -p '
  {"spec":{"config":{"resources":{
    "requests":{"cpu":"200m","memory":"512Mi"},
    "limits":{"cpu":"1","memory":"2Gi"}
  }}}}'
  ```
- **Result:** 31 of 31 subscriptions Active. The operator settles at about 473Mi.
- **Follow-up:** not yet in any setup script. Add it to `field-source-setup-maas-35.sh` (or step 9 of `field-source-enable-all-features-35.sh`) right after RHCL is installed.

---

## 2. GPU ClusterPolicy: DCGM metrics not reaching cluster Prometheus

- **Problem:** all 25 `nvidia-dcgm` and 25 `nvidia-dcgm-exporter` pods were Running and the exporter served metrics on `:9400`. But cluster Prometheus had **no** `DCGM_FI_*` series (`count(DCGM_FI_DEV_GPU_UTIL)` returned empty).
- **Root cause:** the `gpu-cluster-policy` ClusterPolicy did not set `spec.dcgmExporter.serviceMonitor.enabled`, so the GPU operator never created the `nvidia-dcgm-exporter` ServiceMonitor in `nvidia-gpu-operator`. Prometheus only scraped `gpu-operator` and `nvidia-node-status-exporter`.
  - The setup script already creates a DCGM ServiceMonitor in `redhat-ods-monitoring`, but that one only feeds the RHOAI MonitoringStack Prometheus, not cluster Prometheus.
- **Impact:** the OpenShift console GPU dashboards (Observe → Dashboards → NVIDIA DCGM Exporter Dashboard) and the `accelerator_*` recording rules in `nvidia-gpu-operator` had no data. Model serving was not affected.
- **Change applied on `m8hk2`:**
  ```bash
  oc patch clusterpolicy gpu-cluster-policy --type merge \
    -p '{"spec":{"dcgmExporter":{"serviceMonitor":{"enabled":true}}}}'
  ```
  No pods were restarted. The operator created the ServiceMonitor within about 10 seconds.
- **Verify:**
  ```bash
  oc get servicemonitor nvidia-dcgm-exporter -n nvidia-gpu-operator
  oc exec -n openshift-monitoring prometheus-k8s-0 -c prometheus -- \
    curl -s 'http://localhost:9090/api/v1/query?query=count(DCGM_FI_DEV_GPU_UTIL)'
  ```
  Result: 25 of 25 `nvidia-dcgm-exporter` targets `up`, and the count returned 25.
- **Script change:** `field-source-enable-all-features-35.sh`
  - Step 3b: the ClusterPolicy spec now sets `dcgmExporter.serviceMonitor.enabled: true`. If the ClusterPolicy already exists, the script merge-patches it.
  - Step 11: verification reports whether the `nvidia-dcgm-exporter` ServiceMonitor exists.
- **Side note:** every exporter pod showed 3 restarts. These all happened at cluster setup (04:13) because the exporter started before `nv-hostengine` was listening (`Failed to connect to remote hostengine at nvidia-dcgm:5555`). They're harmless and the pods have been stable since.

---

## 3. Worker nodes and GPU capacity

Snapshot during the workshop (about 22 users plus `demo` with a model deployed):

| Pool | Nodes | Usage |
|---|---|---|
| GPU (g6.2xlarge, 1 L4 GPU each) | 25 | 23 of 25 GPUs in use. Only 2 free (`ip-10-0-11-182`, `ip-10-0-18-8`) |
| CPU workers (m5a/m6a.4xlarge) | 12 | CPU 17–66%, memory 12–61%. Plenty of room |

- **The GPU pool is the constraint.** Each user's Gemma model (`redhataigemma-4-e4b-it`, `gpu-profile`) takes one whole GPU node, so the number of GPU nodes sets the maximum number of users with a model.
- At the time of the snapshot, users 1, 3, 6, 8, 10, 18, 23 and 29 had not deployed a model yet. That's 8 users for 2 free GPUs. Any further deployments would stay **Pending**.
- **Recommendation for future runs:** plan for **GPU nodes ≥ number of users + `demo` + 1–2 spare** (for redeploys, since a redeploy briefly needs a second GPU during rollout). Alternatively, have users share an endpoint. Check the AWS G-instance vCPU quota first (see RCA section 6.4: some sandboxes cap at 64 vCPUs, which is 8 × g6.2xlarge).
- **Check capacity:**
  ```bash
  oc get nodes -l node-role.kubernetes.io/worker \
    -o custom-columns=NAME:.metadata.name,TYPE:.metadata.labels.node\\.kubernetes\\.io/instance-type,GPU:.status.allocatable.nvidia\\.com/gpu
  oc get pods -A -o json | jq -r '.items[] | select(.status.phase=="Running")
    | select([.spec.containers[].resources.limits["nvidia.com/gpu"]?]|any)
    | "\(.metadata.namespace) \(.spec.nodeName)"' | sort
  ```

---

## 4. Participant-side issues (no cluster change)

### 4.1 user20: GuideLLM jobs failing
- **Symptom:** 3 EvalHub GuideLLM job pods (`provider_id=guidellm`) in `Error`. Logs show `RuntimeError: Backend validation request failed`, and the model health check returned **404**.
- **Cause 1:** `~/rhoai-evalhub-lab/.env` in the workbench had `MODEL_ENDPOINT=.../user1/redhataigemma-4-e4b-it/v1`. That's another user's URL, and user1 had no model deployed. It was mistyped or pasted wrong when running `setup-env.sh`.
- **Cause 2:** user20's model was first deployed with `default-profile` (no GPU). It was scheduled on a CPU node and vLLM crashed with `Failed to infer device type`. It was later redeployed with `gpu-profile` and is now Ready.
- **Remaining fix:** set `MODEL_ENDPOINT` to `.../user20/redhataigemma-4-e4b-it/v1`, or re-run `setup-env.sh`, then resubmit the jobs.
- **Workshop guide takeaway:** remind users to select **`gpu-profile`** when deploying, and to copy the endpoint URL from **their own** model.

### 4.2 user9: model Ready=False even though the pod is running
- **Symptom:** the vLLM pod is 2/2 Running, but the LLMInferenceService shows `RefsInvalid: Managed HTTPRoute references non-existent Gateway openshift-ingress/openshift-ai-inference`.
- **Cause:** the model was deployed without the MaaS gateway. Every other user uses `maas-default-gateway`.
- **Fix:** redeploy with MaaS enabled (gateway `maas-default-gateway`).

### 4.3 user2: job fails after deleting an MLflow experiment
- **Symptom:** rerunning the Module 2 setup notebook failed 3 times. EvalHub returned HTTP 400: `The MLflow request failed: 'experiment "korean-llm-evaluation" is not active after create'`. No job was created.
- **Cause:** user2 deleted the `korean-llm-evaluation` experiment in the dashboard. In MLflow, deleting an experiment only moves it to a *deleted* state, and the name stays reserved. EvalHub's `get-by-name` lookup does not return deleted experiments, so EvalHub tries to create a new one, and MLflow rejects it (`RESOURCE_ALREADY_EXISTS`, `UNIQUE constraint failed: experiments.workspace, experiments.name`).
- **Affected notebooks:** those with fixed experiment names: Module 2 (`korean-llm-evaluation`), Module 4 (`korean-haerae-eval`), and Module 6 (`guardrail-evaluation`, reference only). Modules 3 and 5 add a timestamp to their experiment names, so they're not affected as long as the cell that sets the timestamp is rerun.
- **Fix for the user:** change the experiment name in the notebook (for example `korean-llm-evaluation-2`) and rerun from that cell. Deleting individual runs is safe.
- **Docs change:** added an IMPORTANT note in Module 2 (*View the Evaluation Results in MLflow*, anchor `#deleted-experiments`) and short NOTEs in Module 3 Step 3.3 and Module 4 Step 4.3 that link to it. Done in both English and Korean.
- **Find affected users:**
  ```bash
  oc logs -n redhat-ods-applications deploy/evalhub -c evalhub --since=12h \
    | grep RESOURCE_ALREADY_EXISTS | grep -o '"tenant":"[^"]*"\|name=[a-z0-9-]*' | paste - - | sort | uniq -c
  ```

### 4.4 Open WebUI and playground: healthy
- All 9 Open WebUI deployments were 1/1 Running.
- Some `lsd-genai-playground` ReplicaSets logged `FailedCreate` (SCC: `fsGroup 1001 is not an allowed group`) during rollout. The replacement ReplicaSets came up and every deployment reached 1/1. No action needed.
