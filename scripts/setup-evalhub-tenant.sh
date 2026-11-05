#!/usr/bin/env bash
# Enable workshop namespaces as EvalHub tenants.
#
# The shared EvalHub service (in EVALHUB_NS) submits evaluation jobs and
# creates MLflow experiments inside each participant's namespace. Without
# the RBAC below, job submission fails with:
#   400 mlflow_request_failed ... PERMISSION_DENIED ... status code: 403
#
# Usage:
#   ./setup-evalhub-tenant.sh user1                 # one namespace
#   ./setup-evalhub-tenant.sh user1 user2 user3     # several namespaces
#   ./setup-evalhub-tenant.sh                       # discover Keycloak users (except admin)
#
#   # From Web Terminal, without cloning:
#   curl -fsSL <raw-url>/scripts/setup-evalhub-tenant.sh | bash
#
# Environment:
#   EVALHUB_NS           EvalHub namespace (default: redhat-ods-applications)
#   WORKSHOP_USERS       Comma-separated namespaces; overrides Keycloak discovery
#   KC_NAMESPACE         Keycloak namespace (default: keycloak)
#   KC_REALM_IMPORT_NAME KeycloakRealmImport name (default: sso)
#
# Namespace arguments take precedence over WORKSHOP_USERS and Keycloak discovery.
# Keycloak usernames must match the existing workshop project names.
#
# Safe to rerun: every resource is applied idempotently.
# The caller needs permission to create Roles and RoleBindings that grant the
# EvalHub ClusterRoles in the target namespace (cluster-admin in this workshop).
set -euo pipefail

EVALHUB_NS="${EVALHUB_NS:-redhat-ods-applications}"
EVALHUB_SA="evalhub-service"
JOB_SA="evalhub-${EVALHUB_NS}-job"
KC_NAMESPACE="${KC_NAMESPACE:-keycloak}"
KC_REALM_IMPORT_NAME="${KC_REALM_IMPORT_NAME:-sso}"

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

    if [[ ${#ns} -gt 63 || ! "$ns" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ || "$ns" == "$EVALHUB_NS" ]]; then
        warn "Invalid participant namespace: ${ns}. Use an existing workshop project name."
        return 1
    fi
    if ! oc get namespace "$ns" >/dev/null 2>&1; then
        warn "Namespace ${ns} is unavailable. Create the participant project before running this script."
        return 1
    fi

    info "Configuring EvalHub tenant RBAC in namespace '${ns}' (as $(oc whoami))..."

    oc apply -f - >/dev/null <<EOF || return 1
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
    # MLflow experiments are not a served Kubernetes resource, so `oc auth can-i`
    # always answers "no". Ask the API server directly with a SubjectAccessReview.
    local mlflow_allowed
    mlflow_allowed=$(oc create -o jsonpath='{.status.allowed}' -f - 2>/dev/null <<EOF || true
apiVersion: authorization.k8s.io/v1
kind: SubjectAccessReview
spec:
  user: ${svc}
  groups: ["system:serviceaccounts", "system:serviceaccounts:${EVALHUB_NS}"]
  resourceAttributes:
    namespace: ${ns}
    group: mlflow.kubeflow.org
    resource: experiments
    verb: create
EOF
)
    if [[ "$mlflow_allowed" == "true" ]]; then
        ok "  ${EVALHUB_SA} can create MLflow experiments"
    else
        warn "  ${EVALHUB_SA} cannot create MLflow experiments in ${ns}"
        failed=1
    fi

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
    if [[ ${#namespaces[@]} -gt 0 ]]; then
        info "Using namespace arguments: ${namespaces[*]}"
    elif [[ -n "${WORKSHOP_USERS:-}" ]]; then
        IFS=',' read -r -a namespaces <<< "$WORKSHOP_USERS"
        [[ ${#namespaces[@]} -gt 0 ]] || fail "WORKSHOP_USERS contains no namespaces."
        info "Using WORKSHOP_USERS: ${namespaces[*]}"
    else
        local kc_users username
        info "Discovering users from KeycloakRealmImport '${KC_REALM_IMPORT_NAME}' in '${KC_NAMESPACE}'..."
        if ! kc_users=$(oc get keycloakrealmimport "$KC_REALM_IMPORT_NAME" -n "$KC_NAMESPACE" \
            -o jsonpath='{.spec.realm.users[*].username}'); then
            fail "Cannot read Keycloak users. Check KC_NAMESPACE and KC_REALM_IMPORT_NAME, or provide namespace arguments or WORKSHOP_USERS."
        fi
        # Use the same username-to-project mapping as workshop provisioning.
        for username in $kc_users; do
            [[ "$username" == "admin" ]] && continue
            namespaces+=("$username")
        done
        [[ ${#namespaces[@]} -gt 0 ]] || fail "No workshop users found in Keycloak (admin excluded). Provide namespace arguments or WORKSHOP_USERS."
        info "Auto-discovered ${#namespaces[@]} workshop namespace(s): ${namespaces[*]}"
    fi

    local rc=0
    for ns in "${namespaces[@]}"; do
        setup_tenant "$ns" || rc=1
        printf '\n'
    done
    exit "$rc"
}

main "$@"
