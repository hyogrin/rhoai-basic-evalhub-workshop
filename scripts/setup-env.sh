bash <<'SETUP'
set -euo pipefail

fail() {
    printf 'ERROR: %s\n' "$1" >&2
    exit 1
}

# Web Terminal is already authenticated as your OpenShift user.
EVALHUB_AUTH_TOKEN=$(oc whoami -t)
[[ -n "$EVALHUB_AUTH_TOKEN" ]] || fail "No OpenShift token is available. Reopen Web Terminal after signing in."

read -r -p "Assigned namespace (user1, user2, user3, ...): " NAMESPACE </dev/tty
read -r -p "Served model ID: " MODEL_NAME </dev/tty
read -r -p "Model API base URL (including /v1 when required): " MODEL_ENDPOINT </dev/tty
read -r -s -p "Model API key (Enter only for an unauthenticated endpoint): " MODEL_API_KEY </dev/tty
printf '\n' >/dev/tty

[[ -n "$NAMESPACE" && -n "$MODEL_NAME" && -n "$MODEL_ENDPOINT" ]] \
    || fail "Namespace, model ID, and model endpoint are required."

EVALHUB_NAMESPACE="$NAMESPACE"
MLFLOW_NAMESPACE=redhat-ods-applications

# Prefer the named EvalHub route, preserving its scheme and base path.
EVALHUB_URL=$(oc get route evalhub -n "$EVALHUB_NAMESPACE" \
    -o go-template='{{if eq .spec.to.name "evalhub"}}{{if .spec.tls}}https{{else}}http{{end}}://{{.spec.host}}{{with .spec.path}}{{.}}{{end}}{{end}}' \
    2>/dev/null || true)

# A Workbench in the same cluster can also use the internal HTTPS service.
if [[ -z "$EVALHUB_URL" ]]; then
    EVALHUB_PORT=$(oc get svc evalhub -n "$EVALHUB_NAMESPACE" \
        -o jsonpath='{.spec.ports[?(@.port==8443)].port}')
    [[ -n "$EVALHUB_PORT" ]] || fail "The expected EvalHub HTTPS service port 8443 was not found."
    EVALHUB_URL="https://evalhub.${EVALHUB_NAMESPACE}.svc.cluster.local:${EVALHUB_PORT}"
fi

# Read the tracking URI explicitly configured on EvalHub, when present.
MLFLOW_TRACKING_URI=$(oc get evalhub evalhub -n "$EVALHUB_NAMESPACE" \
    -o jsonpath='{.spec.env[?(@.name=="MLFLOW_TRACKING_URI")].value}' \
    2>/dev/null || true)

# Otherwise, verify and use this lab's shared HTTPS MLflow service.
if [[ -z "$MLFLOW_TRACKING_URI" ]]; then
    MLFLOW_PORT=$(oc get svc mlflow -n "$MLFLOW_NAMESPACE" \
        -o jsonpath='{.spec.ports[?(@.port==8443)].port}')
    [[ -n "$MLFLOW_PORT" ]] || fail "The expected MLflow HTTPS service port 8443 was not found."
    MLFLOW_TRACKING_URI="https://mlflow.${MLFLOW_NAMESPACE}.svc:${MLFLOW_PORT}"
fi

# Expand a short MLflow service hostname relative to EvalHub's namespace.
case "$MLFLOW_TRACKING_URI" in
    http://mlflow:*|https://mlflow:*)
        MLFLOW_SCHEME="${MLFLOW_TRACKING_URI%%://*}"
        MLFLOW_ADDRESS="${MLFLOW_TRACKING_URI#*://mlflow:}"
        MLFLOW_TRACKING_URI="${MLFLOW_SCHEME}://mlflow.${EVALHUB_NAMESPACE}.svc:${MLFLOW_ADDRESS}"
        ;;
esac

# Single quotes preserve spaces and # characters when python-dotenv reads values.
print_env() {
    local value="$2"
    local escaped_backslash='\\'
    local escaped_quote="\\'"
    value="${value//\\/$escaped_backslash}"
    value="${value//\'/$escaped_quote}"
    printf "%s='%s'\n" "$1" "$value"
}

printf '\n# BEGIN .env - copy from NAMESPACE through MLFLOW_TRACKING_URI\n'
for key in NAMESPACE MODEL_NAME MODEL_ENDPOINT MODEL_API_KEY \
    EVALHUB_URL EVALHUB_AUTH_TOKEN MLFLOW_TRACKING_URI; do
    print_env "$key" "${!key}"
done
printf '# END .env\n'
SETUP