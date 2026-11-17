# RCA: MaaS subscriptions Degraded ("1 of 1 TokenRateLimitPolicies not accepted")

| | |
|---|---|
| **Environment** | RHDP sandbox `m8hk2` (`api.ocp.m8hk2.sandbox697.opentlc.com`), OCP 4.22, RHOAI 3.5.3, Red Hat Connectivity Link (RHCL) 1.4.3 |
| **Date** | 2026-11-17 |
| **Impact** | Workshop users could not use their MaaS models. Subscriptions showed **Degraded**, auth policies stayed **Pending**, and models stayed **Pending** in MaaS. |
| **Fix** | Raise the Kuadrant operator memory limit from 300Mi to 2Gi through its OLM Subscription |
| **Time to recover after the fix** | About 5 minutes: roughly 4 for OLM to roll out the change, and seconds for the backlog to clear |

---

## 1. Symptoms

- In the dashboard, some `MaaSSubscription`s (for example `user15-workshop-gemma4-basic`) showed:
  ```
  Ready=False  PartialFailure: 1 of 1 TokenRateLimitPolicies not accepted
  ```
- The matching `MaaSAuthPolicy` objects stayed `Pending`.
- The `MaaSModelRef` in those users' namespaces stayed `Pending` with `No active subscription and auth policy pairing found`, even though subscriptions existed.
- The `TokenRateLimitPolicy` in the affected namespaces (for example `user15/maas-trlp-redhataigemma-4-e4b-it`) had **no status conditions at all**. The policy controller had never processed it.
- Subscriptions created **early** worked (users 2, 5, 7, 12, 16, 25). Subscriptions created **later** did not (users 13, 15, 17, 21, 22, 30).
- Even the policies that were accepted showed `Enforced=False` ("waiting for the following components to sync: [Limitador]").

## 2. Root cause

**The Kuadrant operator (`kuadrant-operator-controller-manager`) was OOMKilled in a crash loop.**

```
$ oc get pods -n redhat-connectivity-link-operator
kuadrant-operator-controller-manager-...   0/1   CrashLoopBackOff   12

lastState.terminated.reason = OOMKilled   exitCode = 137
resources: requests {cpu: 200m, memory: 200Mi}  limits {cpu: 200m, memory: 300Mi}
```

- RHCL 1.4.3 installs the operator with a **300Mi memory limit** by default.
- On startup, the operator caches every Gateway API and Kuadrant object, then reconciles them all. Each MaaS model, subscription and auth policy adds objects. At the time of the incident (about 30 users, one model each, two tiers each), the cluster had:

  | Object | Count |
  |---|---|
  | AuthConfig | 259 |
  | HTTPRoute | 56 |
  | TokenRateLimitPolicy | 17 |

- **The crash loop:** the operator started, began reconciling, and was killed after about 4 seconds. It never got far enough to write status to the new `TokenRateLimitPolicy` objects.
- **Why it shows up in MaaS:** the MaaS controller reads that status, so it reported `1 of 1 TokenRateLimitPolicies not accepted` → subscription **Degraded** → auth policy **Pending** → model ref **Pending**.
- **Proof:** after the fix, the operator settled at about **473Mi**, well above the old 300Mi limit.

**Why only some users broke:** objects created while the operator could still fit in 300Mi were processed. Once the object count passed the threshold, every new subscription got stuck. **Any cluster will hit this once enough users create MaaS subscriptions.**

### Not the cause (ruled out)
| Suspect | Finding |
|---|---|
| Limitador | `Ready=True`. Its generation matched what it had applied (`20/20`), and it had 27 limits loaded. The `Enforced=False` status was stale because the operator was down. |
| Kuadrant CR / Authorino | Both `Ready` |
| HTTPRoute / Gateway | The route was `Accepted=True` on `maas-default-gateway` |
| `SpecPriorityDuplicate=True` on subscriptions | This only notes that many subscriptions share `priority: 10`. It is informational and does not block anything. |

## 3. Fix

Raise the operator's resources **through the OLM Subscription**. If you edit the Deployment directly, OLM reverts it.

```bash
oc patch subscriptions.operators.coreos.com rhcl-operator \
  -n redhat-connectivity-link-operator --type=merge -p '
{"spec":{"config":{"resources":{
  "requests":{"cpu":"200m","memory":"512Mi"},
  "limits":{"cpu":"1","memory":"2Gi"}
}}}}'
```

- OLM can take **3 to 5 minutes** to roll out the Deployment again. Wait for it.
- Once the new pod is `Running`, the backlog clears within seconds. You don't need to recreate any subscriptions or policies.

**To roll back:**
```bash
oc patch subscriptions.operators.coreos.com rhcl-operator \
  -n redhat-connectivity-link-operator --type=json -p '[{"op":"remove","path":"/spec/config"}]'
```

## 4. Verify

```bash
# 1. The operator picked up the new limit and is healthy (expect 2Gi, 1/1 Running, 0 restarts)
oc get deploy kuadrant-operator-controller-manager -n redhat-connectivity-link-operator \
  -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}{"\n"}'
oc get pods -n redhat-connectivity-link-operator | grep kuadrant-operator-controller
oc adm top pod -n redhat-connectivity-link-operator | grep kuadrant-operator-controller

# 2. All subscriptions are Active
oc get maassubscription -n models-as-a-service -o custom-columns=NAME:.metadata.name,PHASE:.status.phase

# 3. All auth policies are Active
oc get maasauthpolicy -n models-as-a-service -o custom-columns=NAME:.metadata.name,PHASE:.status.phase

# 4. Every TokenRateLimitPolicy is Accepted and Enforced
oc get tokenratelimitpolicy -A -o go-template='{{range .items}}{{.metadata.namespace}} {{range .status.conditions}}{{.type}}={{.status}} {{end}}{{"\n"}}{{end}}'

# 5. Model refs are Ready. Anything still Pending has no subscription + auth policy pair.
oc get maasmodelref -A -o custom-columns=NS:.metadata.namespace,PHASE:.status.phase
```

Result on `m8hk2`:

| Before | After |
|---|---|
| 6 Degraded subscriptions | 31 out of 31 Active |
| 8 or more Pending auth policies | All Active |
| User TokenRateLimitPolicies with no status, or Accepted but `Enforced=False` | All 16 user policies Accepted and Enforced |

---

## 5. Prep checklist for new environments

Do this **after** `field-source-enable-all-features-35.sh` and `field-source-setup-maas-35.sh`, and **before** users create MaaS subscriptions.

1. **Apply the Kuadrant operator memory patch** from section 3. Do it up front; don't wait for the crash.
2. **Wait for the rollout,** then check that the limit is `2Gi` (section 4, step 1).
3. **Size it for the workshop.** About 470Mi was used with roughly 30 users × 1 model × 2 tiers. Increase the limit if you plan to have many more users or models per user.
4. **Watch memory during the workshop:**
   `oc adm top pod -n redhat-connectivity-link-operator`
5. **Clusters already prepared with the default 300Mi** (for example `nfsdx` / sandbox2388) need the same patch.

> Consider adding the patch to `field-source-setup-maas-35.sh` right after RHCL is installed, so new environments get it automatically.

---

## 6. Related issues found during the same session

These are not caused by the OOM, but they produced similar "model not working" reports.

### 6.1 Model Pending: no subscription or auth policy pair
- **Symptom:** the `MaaSModelRef` shows `Pending`: *Awaiting governance pairing*, and there is no `TokenRateLimitPolicy` in the namespace.
- **Cause:** the user never created, or deleted, their `MaaSSubscription` and `MaaSAuthPolicy` (seen for `user4`, `user20`, `user21`, `user24`, `user27`, `demo`).
- **Fix:** create both. Each must reference `userN/<model-name>` and the user's group.
- **Check:**
  ```bash
  oc get maassubscription,maasauthpolicy -n models-as-a-service | grep userN
  ```

### 6.2 Playground: `429 Too Many Requests` after one or two messages
- **Cause:** the `basic` subscription had `tokenRateLimits: 100 / 1m`, which is roughly one reply. The playground shows this as a generic error. The log of the playground server pod (`lsd-genai-playground`) shows:
  ```
  exc=Too Many Requests
  ```
- **Fix:** select the `premium` subscription (10,000 per minute) in the playground, or raise the basic limit.
- The playground's config holds the placeholder token `VLLM_API_TOKEN_1=fake`. **This is expected:** the dashboard sends the user's MaaS key with each request.

### 6.3 Playground: MaaS model greyed out in the model dropdown
- **How it decides:** the playground frontend enables a MaaS model only if `/api/v1/maas/models?namespace=<ns>` returns it with `ready: true`. The AI asset label `opendatahub.io/genai-asset=true` is **not** needed for MaaS models.
- **Check from the backend:**
  ```bash
  T=$(oc whoami -t)
  oc exec -n redhat-ods-applications deploy/gen-ai-ui -- \
    curl -sk -H "x-forwarded-access-token: $T" \
    "https://localhost:8143/api/v1/maas/models?namespace=userN"
  ```
- **If the backend returns the model as ready:** the browser loaded the list before it was complete. Hard-refresh the page, or use **Update configuration** in the playground.
- **If the model is missing from the backend response:** see 6.1.

### 6.4 GPU nodes: AWS vCPU quota
- **What happened:** RHDP sandboxes `4znkb` and `nfsdx` capped **G and VT instances at 64 vCPUs** (8 × `g6.2xlarge`). Machines past the cap fail with `You have requested more vCPU capacity than your current vCPU limit of 64`. `m8hk2` ran 25 × `g6.2xlarge` without hitting a limit.
- **Quota is per region and per instance family.** Scaling down `m5a` workers does not free G quota, and L40S (`g6e`) instances use the same G bucket.
- **Before scaling GPUs**, check the quota in AWS **Service Quotas → EC2 → "Running On-Demand G and VT instances"** (region `us-east-2`), or request an increase through RHDP.
