#!/usr/bin/env bash
# Collect workshop configuration in OpenShift Web Terminal.
set -euo pipefail

fail() {
    printf 'ERROR: %s\n' "$1" >&2
    exit 1
}

# Single quotes preserve spaces and # characters when python-dotenv reads values.
print_env() {
    local value="$2"
    local escaped_backslash='\\'
    local escaped_quote="\\'"
    value="${value//\\/$escaped_backslash}"
    value="${value//\'/$escaped_quote}"
    printf "%s='%s'\n" "$1" "$value"
}

main() {
    command -v oc >/dev/null 2>&1 || fail "The oc CLI is required. Run this script in OpenShift Web Terminal."
    if ! { exec 3<>/dev/tty; } 2>/dev/null; then
        fail "An interactive terminal is required. Run this script in OpenShift Web Terminal."
    fi

    # Read prompts from the terminal, leaving stdin available for curl | bash.
    if ! EVALHUB_AUTH_TOKEN=$(oc whoami -t); then
        fail "No OpenShift login is available. Reopen Web Terminal after signing in."
    fi
    [[ -n "$EVALHUB_AUTH_TOKEN" ]] || fail "No OpenShift token is available. Reopen Web Terminal after signing in."

    read -r -u 3 -p "Assigned namespace (user1, user2, user3, ...): " NAMESPACE
    read -r -u 3 -p "Served model ID: " MODEL_NAME
    read -r -u 3 -p "Model API base URL (including /v1 when required): " MODEL_ENDPOINT
    read -r -s -u 3 -p "Model API key (Enter only for an unauthenticated endpoint): " MODEL_API_KEY
    printf '\n' >&3

    [[ -n "$NAMESPACE" && -n "$MODEL_NAME" && -n "$MODEL_ENDPOINT" ]] \
        || fail "Namespace, model ID, and model endpoint are required."

    # Shared services are hosted separately from the user's evaluation tenant.
    EVALHUB_NAMESPACE="${EVALHUB_NAMESPACE:-redhat-ods-applications}"
    MLFLOW_NAMESPACE="${MLFLOW_NAMESPACE:-redhat-ods-applications}"

    # Prefer the named EvalHub route, preserving its scheme and base path.
    EVALHUB_URL=$(oc get route evalhub -n "$EVALHUB_NAMESPACE" \
        -o go-template='{{if eq .spec.to.name "evalhub"}}{{if .spec.tls}}https{{else}}http{{end}}://{{.spec.host}}{{with .spec.path}}{{.}}{{end}}{{end}}' \
        2>/dev/null || true)

    # A Workbench in the same cluster can also use the internal HTTPS service.
    if [[ -z "$EVALHUB_URL" ]]; then
        if ! EVALHUB_PORT=$(oc get svc evalhub -n "$EVALHUB_NAMESPACE" \
            -o jsonpath='{.spec.ports[?(@.port==8443)].port}'); then
            fail "Could not read service evalhub in namespace ${EVALHUB_NAMESPACE}. Verify service access or set EVALHUB_NAMESPACE to its deployment namespace."
        fi
        [[ -n "$EVALHUB_PORT" ]] || fail "Service evalhub in namespace ${EVALHUB_NAMESPACE} does not expose the expected HTTPS port 8443."
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

    printf '\n# BEGIN .env - copy from NAMESPACE through MLFLOW_TRACKING_URI\n'
    for key in NAMESPACE MODEL_NAME MODEL_ENDPOINT MODEL_API_KEY \
        EVALHUB_URL EVALHUB_AUTH_TOKEN MLFLOW_TRACKING_URI; do
        print_env "$key" "${!key}"
    done
    printf '# END .env\n'
}

# Start only after Bash has parsed the complete function definition.
main "$@"
