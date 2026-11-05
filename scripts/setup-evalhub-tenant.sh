#!/usr/bin/env bash
# Enable one or more namespaces as EvalHub tenants.
#
# The shared EvalHub service (in EVALHUB_NS) submits evaluation jobs and
# creates MLflow experiments inside each participant's namespace. Without
# the RBAC below, job submission fails with:
#   400 mlflow_request_failed ... PERMISSION_DENIED ... status code: 403
#
# Usage:
#   ./setup-evalhub-tenant.sh user1                 # one namespace
#   ./setup-evalhub-tenant.sh user1 user2 user3     # several namespaces
#   ./setup-evalhub-tenant.sh                       # prompts for a namespace
#
#   # From Web Terminal, without cloning:
#   curl -fsSL <raw-url>/scripts/setup-evalhub-tenant.sh | bash -s -- user1
#
# Environment:
#   EVALHUB_NS   Namespace where EvalHub runs (default: redhat-ods-applications)
#
# Safe to rerun: every resource is applied idempotently.
# The caller needs permission to create Roles and RoleBindings that grant the
# EvalHub ClusterRoles in the target namespace (cluster-admin in this workshop).
set -euo pipefail

EVALHUB_NS="${EVALHUB_NS:-redhat-ods-applications}"
EVALHUB_SA="evalhub-service"
JOB_SA="evalhub-${EVALHUB_NS}-job"

info()    { printf '[INFO] %s\n' "$1"; }
ok()      { printf '[OK]   %s\n' "$1"; }
warn()    { printf '[WARN] %s\n' "$1" >&2; }
fail()    { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

preflight() {
    command -v oc >/dev/null 2>&1 || fail "The oc CLI is required."
    oc whoami >/dev/null 2>&1 || fail "Not logged in to OpenShift. Run 'oc login' first."
    oc get sa "$EVALHUB_SA" -n "$EVALHUB_NS" >/dev/null 2>&1 \
        || fail "ServiceAccount ${EVALHUB_SA} not found in ${EVALHUB_NS}. Is EvalHub deployed? Set EVALHUB_NS if it runs elsewhere."
}

setup_tenant() {
    local ns="$1"

    [[ "$ns" != "$EVALHUB_NS" ]] || fail "Target namespace must be a user namespace, not ${EVALHUB_NS}."
    oc get namespace "$ns" >/dev/null 2>&1 || fail "Namespace ${ns} does not exist."

    info "Configuring EvalHub tenant RBAC in namespace '${ns}' (as $(oc whoami))..."

    oc apply -f - >/dev/null <<EOF
# EvalHub service: create MLflow experiments in this namespace's workspace.
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: evalhub-central-mlflow-access
  namespace: ${ns}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: trustyai-service-operator-evalhub-mlflow-access
subjects:
- kind: ServiceAccount
  name: ${EVALHUB_SA}
  namespace: ${EVALHUB_NS}
---
# EvalHub service: create and delete evaluation Jobs.
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: evalhub-central-jobs-writer
  namespace: ${ns}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: trustyai-service-operator-evalhub-jobs-writer
subjects:
- kind: ServiceAccount
  name: ${EVALHUB_SA}
  namespace: ${EVALHUB_NS}
---
# EvalHub service: manage per-job ConfigMaps.
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: evalhub-central-job-config
  namespace: ${ns}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: trustyai-service-operator-evalhub-job-config
subjects:
- kind: ServiceAccount
  name: ${EVALHUB_SA}
  namespace: ${EVALHUB_NS}
---
# EvalHub service: read the model-api-key Secret created by the notebooks.
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: evalhub-secret-access
  namespace: ${ns}
rules:
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get", "list", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: evalhub-secret-access
  namespace: ${ns}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: evalhub-secret-access
subjects:
- kind: ServiceAccount
  name: ${EVALHUB_SA}
  namespace: ${EVALHUB_NS}
---
# Identity used by evaluation job pods in this namespace.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${JOB_SA}
  namespace: ${ns}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: evalhub-job-edit
  namespace: ${ns}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: edit
subjects:
- kind: ServiceAccount
  name: ${JOB_SA}
  namespace: ${ns}
---
# Job pods: log to MLflow experiments in this namespace's workspace.
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: evalhub-job-mlflow-access
  namespace: ${ns}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: trustyai-service-operator-evalhub-mlflow-jobs-access
subjects:
- kind: ServiceAccount
  name: ${JOB_SA}
  namespace: ${ns}
---
# Service CA bundle so job pods can verify EvalHub/MLflow HTTPS endpoints.
# OpenShift's service-ca operator fills in service-ca.crt automatically.
apiVersion: v1
kind: ConfigMap
metadata:
  name: evalhub-service-ca
  namespace: ${ns}
  annotations:
    service.beta.openshift.io/inject-cabundle: "true"
EOF
    ok "RoleBindings, Role, ServiceAccount, and CA ConfigMap applied in '${ns}'"

    verify_tenant "$ns"
}

verify_tenant() {
    local ns="$1" svc="system:serviceaccount:${EVALHUB_NS}:${EVALHUB_SA}" failed=0

    check() {
        if oc auth can-i "$@" -n "$ns" --as="$svc" >/dev/null 2>&1; then
            ok "  ${EVALHUB_SA} can $*"
        else
            warn "  ${EVALHUB_SA} cannot $* in ${ns}"
            failed=1
        fi
    }
    check create experiments.mlflow.kubeflow.org
    check create jobs.batch
    check create configmaps
    check get secrets

    # The CA bundle is injected asynchronously; give it a few seconds.
    for _ in 1 2 3 4 5; do
        if [[ -n "$(oc get configmap evalhub-service-ca -n "$ns" -o jsonpath='{.data.service-ca\.crt}' 2>/dev/null)" ]]; then
            ok "  evalhub-service-ca populated"
            break
        fi
        sleep 2
    done || true
    [[ -n "$(oc get configmap evalhub-service-ca -n "$ns" -o jsonpath='{.data.service-ca\.crt}' 2>/dev/null)" ]] \
        || warn "  evalhub-service-ca not populated yet; it should fill in shortly"

    if [[ "$failed" -eq 0 ]]; then
        ok "Namespace '${ns}' is ready for EvalHub jobs"
    else
        warn "Namespace '${ns}' is missing permissions. Ask your instructor to rerun this script as cluster-admin."
        return 1
    fi
}

main() {
    preflight

    local namespaces=("$@")
    if [[ ${#namespaces[@]} -eq 0 ]]; then
        local ns=""
        if { exec 3<>/dev/tty; } 2>/dev/null; then
            read -r -u 3 -p "Namespace to enable for EvalHub (user1, user2, ...): " ns
        fi
        [[ -n "$ns" ]] || fail "No namespace given. Usage: $0 <namespace> [namespace ...]"
        namespaces=("$ns")
    fi

    local rc=0
    for ns in "${namespaces[@]}"; do
        setup_tenant "$ns" || rc=1
        printf '\n'
    done
    exit "$rc"
}

main "$@"
