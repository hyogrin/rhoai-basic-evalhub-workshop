#!/usr/bin/env bash
###############################################################################
# setup-evalhub-tenant.sh
#
# Enable YOUR OpenShift AI project (namespace) as an EvalHub tenant, so the
# shared EvalHub service can run evaluation jobs in it and the jobs can report
# status and log results to MLflow.
#
# Run it in OpenShift Web Terminal, signed in as your workshop user:
#
#   curl -fsSL https://raw.githubusercontent.com/hyogrin/rhoai-basic-evalhub-workshop/refs/heads/main/scripts/setup-evalhub-tenant.sh | bash
#
# The script proposes your signed-in OpenShift user name (oc whoami) as the
# namespace. Press Enter to accept it, or type a different project name.
# To skip the prompt (for example, instructors):
#
#   NAMESPACE=user1 bash setup-evalhub-tenant.sh
#
# What it creates in your namespace (idempotent, safe to re-run):
#   - RoleBindings that let the EvalHub service create MLflow experiments,
#     evaluation Jobs, per-job ConfigMaps, and job Secrets
#   - The ServiceAccount used by evaluation job pods, with permission to report
#     status events, edit resources, and log to MLflow
#   - ConfigMap evalhub-service-ca (OpenShift injects the service CA bundle)
#
# What it does NOT do (cluster-level, done by the instructor/enable-all script):
#   - EvalHub / MLflow deployment
#   - NetworkPolicy evalhub-allow-tenant-jobs in the EvalHub namespace
#   - Refreshing EvalHub's MLflow workspace probe
#
# Resource names and contents match setup_evalhub_tenants() in
# rhoai-field-source-setup-guide/scripts/workshop-prep/setup_workbench_by_users.sh,
# so running both is safe. Keep the two in sync.
#
# Environment variables:
#   NAMESPACE           Target project; skips the prompt (default: your OpenShift user name)
#   EVALHUB_NAMESPACE   Shared EvalHub namespace (default: redhat-ods-applications)
###############################################################################
set -euo pipefail

if [[ -t 1 ]]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; CYAN=$'\033[0;36m'; NC=$'\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; NC=''
fi
info()    { printf '%s[INFO]%s %s\n' "$CYAN" "$NC" "$*"; }
success() { printf '%s[OK]%s   %s\n' "$GREEN" "$NC" "$*"; }
warn()    { printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$*"; }
fail()    { printf '%s[ERR]%s  %s\n' "$RED" "$NC" "$*" >&2; exit 1; }

EVALHUB_NAMESPACE="${EVALHUB_NAMESPACE:-redhat-ods-applications}"
EVALHUB_SA="evalhub-service"
JOB_SA="evalhub-${EVALHUB_NAMESPACE}-job"
REQUIRED_CLUSTERROLES=(
    trustyai-service-operator-evalhub-mlflow-access
    trustyai-service-operator-evalhub-jobs-writer
    trustyai-service-operator-evalhub-job-config
    trustyai-service-operator-evalhub-mlflow-jobs-access
)

# Each participant's project is named after their OpenShift user name, so that
# is the default. Participants press Enter to accept it or type another project.
# The prompt reads /dev/tty so curl | bash keeps working; without a terminal, or
# when NAMESPACE is set, the script continues without asking.
resolve_namespace() {
    local username="$1" answer=""
    if [[ -z "${NAMESPACE:-}" ]]; then
        if { exec 3<>/dev/tty; } 2>/dev/null; then
            read -r -u 3 -p "Assigned namespace [${username}]: " answer
            exec 3>&-
        fi
        NAMESPACE="${answer:-$username}"
    fi
    if [[ ${#NAMESPACE} -gt 63 || ! "$NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
        fail "'${NAMESPACE}' is not a valid project name. Enter your workshop project, for example user1."
    fi
    [[ "$NAMESPACE" != "$EVALHUB_NAMESPACE" ]] \
        || fail "Use your own project, not the shared EvalHub namespace (${EVALHUB_NAMESPACE})."
}

# Prerequisites that participants can check. Missing shared services are fatal;
# checks the user is not allowed to perform are skipped with a warning.
check_prerequisites() {
    local out role

    oc get namespace "$NAMESPACE" >/dev/null 2>&1 \
        || oc get project "$NAMESPACE" >/dev/null 2>&1 \
        || fail "Project '${NAMESPACE}' was not found or you cannot access it. Check the namespace name."

    [[ "$(oc auth can-i create rolebindings -n "$NAMESPACE" 2>/dev/null)" == yes ]] \
        || fail "You cannot create RoleBindings in '${NAMESPACE}'. You need admin on this project; ask your instructor."

    if out=$(oc get sa "$EVALHUB_SA" -n "$EVALHUB_NAMESPACE" 2>&1); then
        success "EvalHub service account found in ${EVALHUB_NAMESPACE}"
    elif [[ "$out" == *NotFound* || "$out" == *"not found"* ]]; then
        fail "EvalHub is not deployed in ${EVALHUB_NAMESPACE} (service account ${EVALHUB_SA} is missing). Ask your instructor."
    else
        warn "Cannot read ${EVALHUB_NAMESPACE}/${EVALHUB_SA}; skipping the EvalHub deployment check."
    fi

    for role in "${REQUIRED_CLUSTERROLES[@]}"; do
        if out=$(oc get clusterrole "$role" 2>&1); then
            continue
        elif [[ "$out" == *NotFound* || "$out" == *"not found"* ]]; then
            fail "ClusterRole ${role} is missing. The TrustyAI/EvalHub installation is incomplete; ask your instructor."
        else
            warn "Cannot read ClusterRoles; skipping the TrustyAI ClusterRole check."
            break
        fi
    done
}

# A RoleBinding's roleRef is immutable, so `oc apply` cannot update a binding
# that already exists with the same name but points to a different role (for
# example, from an older version of this script or a manual fix). Delete only
# such mismatched bindings so the apply below recreates them; matching bindings
# are left untouched. This keeps re-runs safe.
# Usage: reset_mismatched_rolebinding <name> <Role|ClusterRole> <role-name>
reset_mismatched_rolebinding() {
    local name="$1" kind="$2" role="$3" current
    current=$(oc get rolebinding "$name" -n "$NAMESPACE" \
        -o jsonpath='{.roleRef.kind}/{.roleRef.name}' 2>/dev/null) || return 0
    if [[ "$current" != "${kind}/${role}" ]]; then
        warn "RoleBinding ${name} points to ${current}; recreating it for ${kind}/${role}"
        oc delete rolebinding "$name" -n "$NAMESPACE" >/dev/null \
            || fail "Could not replace RoleBinding ${name} in '${NAMESPACE}'."
    fi
}

apply_tenant_resources() {
    reset_mismatched_rolebinding evalhub-central-mlflow-access ClusterRole trustyai-service-operator-evalhub-mlflow-access
    reset_mismatched_rolebinding evalhub-central-jobs-writer   ClusterRole trustyai-service-operator-evalhub-jobs-writer
    reset_mismatched_rolebinding evalhub-central-job-config    ClusterRole trustyai-service-operator-evalhub-job-config
    reset_mismatched_rolebinding evalhub-secret-access         Role        evalhub-secret-access
    reset_mismatched_rolebinding "${JOB_SA}-access-rb"         Role        "${JOB_SA}-access-role"
    reset_mismatched_rolebinding evalhub-job-edit              ClusterRole edit
    reset_mismatched_rolebinding evalhub-job-mlflow-access     ClusterRole trustyai-service-operator-evalhub-mlflow-jobs-access

    info "Configuring EvalHub tenant resources in '${NAMESPACE}'..."
    oc apply -f - >/dev/null <<EOF || fail "Could not apply EvalHub tenant resources in '${NAMESPACE}'. See the oc error above."
# EvalHub service: create MLflow experiments in this namespace's workspace.
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: evalhub-central-mlflow-access
  namespace: ${NAMESPACE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: trustyai-service-operator-evalhub-mlflow-access
subjects:
- kind: ServiceAccount
  name: ${EVALHUB_SA}
  namespace: ${EVALHUB_NAMESPACE}
---
# EvalHub service: create and delete evaluation Jobs.
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: evalhub-central-jobs-writer
  namespace: ${NAMESPACE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: trustyai-service-operator-evalhub-jobs-writer
subjects:
- kind: ServiceAccount
  name: ${EVALHUB_SA}
  namespace: ${EVALHUB_NAMESPACE}
---
# EvalHub service: manage per-job ConfigMaps.
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: evalhub-central-job-config
  namespace: ${NAMESPACE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: trustyai-service-operator-evalhub-job-config
subjects:
- kind: ServiceAccount
  name: ${EVALHUB_SA}
  namespace: ${EVALHUB_NAMESPACE}
---
# EvalHub service: manage evaluation job credentials in this namespace.
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: evalhub-secret-access
  namespace: ${NAMESPACE}
rules:
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get", "list", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: evalhub-secret-access
  namespace: ${NAMESPACE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: evalhub-secret-access
subjects:
- kind: ServiceAccount
  name: ${EVALHUB_SA}
  namespace: ${EVALHUB_NAMESPACE}
---
# Identity used by evaluation job pods in this namespace.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${JOB_SA}
  namespace: ${NAMESPACE}
---
# Job pods: report progress and completion events to EvalHub.
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${JOB_SA}-access-role
  namespace: ${NAMESPACE}
rules:
- apiGroups: ["trustyai.opendatahub.io"]
  resources: ["status-events"]
  verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${JOB_SA}-access-rb
  namespace: ${NAMESPACE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ${JOB_SA}-access-role
subjects:
- kind: ServiceAccount
  name: ${JOB_SA}
  namespace: ${NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: evalhub-job-edit
  namespace: ${NAMESPACE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: edit
subjects:
- kind: ServiceAccount
  name: ${JOB_SA}
  namespace: ${NAMESPACE}
---
# Job pods: log to MLflow experiments in this namespace's workspace.
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: evalhub-job-mlflow-access
  namespace: ${NAMESPACE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: trustyai-service-operator-evalhub-mlflow-jobs-access
subjects:
- kind: ServiceAccount
  name: ${JOB_SA}
  namespace: ${NAMESPACE}
---
# Service CA bundle so job pods can verify EvalHub/MLflow HTTPS endpoints.
# OpenShift's service-ca operator fills in service-ca.crt automatically.
apiVersion: v1
kind: ConfigMap
metadata:
  name: evalhub-service-ca
  namespace: ${NAMESPACE}
  annotations:
    service.beta.openshift.io/inject-cabundle: "true"
EOF
    success "Tenant resources applied in '${NAMESPACE}'"
}

# Ask the API server, via a LocalSubjectAccessReview in this namespace, whether a
# service account may perform an action. Project admins can create these.
# Usage: check_access <serviceaccount-user> <verb> <resource> [group]
check_access() {
    local svc="$1" verb="$2" resource="$3" group="${4:-}" svc_ns allowed label
    svc_ns="${svc#system:serviceaccount:}"
    svc_ns="${svc_ns%%:*}"
    label="${group:+${group}/}${resource}"
    allowed=$(oc create -o jsonpath='{.status.allowed}' -f - 2>/dev/null <<EOF || true
apiVersion: authorization.k8s.io/v1
kind: LocalSubjectAccessReview
metadata:
  namespace: ${NAMESPACE}
spec:
  user: ${svc}
  groups: ["system:serviceaccounts", "system:serviceaccounts:${svc_ns}", "system:authenticated"]
  resourceAttributes:
    namespace: ${NAMESPACE}
    group: "${group}"
    resource: ${resource}
    verb: ${verb}
EOF
)
    if [[ "$allowed" == true ]]; then
        success "${svc##*:} can ${verb} ${label}"
    else
        warn "${svc##*:} cannot ${verb} ${label}"
        return 1
    fi
}

verify_tenant() {
    local central_svc="system:serviceaccount:${EVALHUB_NAMESPACE}:${EVALHUB_SA}"
    local job_svc="system:serviceaccount:${NAMESPACE}:${JOB_SA}"
    local failed=0 attempt ca_bundle=""

    info "Verifying permissions in '${NAMESPACE}'..."
    check_access "$central_svc" create experiments mlflow.kubeflow.org || failed=1
    check_access "$central_svc" get    experiments mlflow.kubeflow.org || failed=1
    check_access "$central_svc" create jobs batch                     || failed=1
    check_access "$central_svc" create configmaps                     || failed=1
    check_access "$central_svc" get    secrets                        || failed=1
    check_access "$job_svc"     create experiments mlflow.kubeflow.org || failed=1
    check_access "$job_svc"     get    experiments mlflow.kubeflow.org || failed=1
    check_access "$job_svc"     create pods                           || failed=1
    check_access "$job_svc"     get    configmaps                     || failed=1
    check_access "$job_svc"     get    secrets                        || failed=1
    check_access "$job_svc"     create status-events trustyai.opendatahub.io || failed=1

    # Service CA injection is asynchronous; wait up to ~20s.
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        ca_bundle=$(oc get configmap evalhub-service-ca -n "$NAMESPACE" \
            -o jsonpath='{.data.service-ca\.crt}' 2>/dev/null || true)
        [[ -z "$ca_bundle" ]] || break
        sleep 2
    done
    if [[ -n "$ca_bundle" ]]; then
        success "evalhub-service-ca contains the service CA bundle"
    else
        warn "evalhub-service-ca is still empty. Wait a minute and re-run this script."
        failed=1
    fi

    return "$failed"
}

# Read-only check of the shared NetworkPolicy the instructor applies. Without it,
# jobs complete but stay "pending" in EvalHub. Never fatal for participants.
check_shared_network_policy() {
    local out
    if out=$(oc get networkpolicy evalhub-allow-tenant-jobs -n "$EVALHUB_NAMESPACE" 2>&1); then
        success "Shared NetworkPolicy evalhub-allow-tenant-jobs is present"
    elif [[ "$out" == *NotFound* || "$out" == *"not found"* ]]; then
        warn "NetworkPolicy evalhub-allow-tenant-jobs is missing in ${EVALHUB_NAMESPACE}."
        warn "Evaluation jobs may finish but stay 'pending'. Tell your instructor."
    else
        info "Cannot read NetworkPolicies in ${EVALHUB_NAMESPACE}; skipping that check."
    fi
}

main() {
    local me
    command -v oc >/dev/null 2>&1 || fail "The oc CLI is required. Run this script in OpenShift Web Terminal."
    me=$(oc whoami 2>/dev/null) || fail "No OpenShift login is available. Reopen Web Terminal after signing in."

    resolve_namespace "$me"
    info "Signed in as ${me}; configuring namespace '${NAMESPACE}' (EvalHub: ${EVALHUB_NAMESPACE})"

    check_prerequisites
    apply_tenant_resources
    check_shared_network_policy

    if verify_tenant; then
        printf '\n'
        success "Namespace '${NAMESPACE}' is ready for EvalHub evaluation jobs."
    else
        printf '\n'
        fail "Some checks failed for '${NAMESPACE}'. Resources were applied; wait a minute and re-run, or ask your instructor."
    fi
}

# Start only after Bash has parsed the complete script (safe for curl | bash).
main "$@"
