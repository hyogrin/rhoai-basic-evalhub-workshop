#!/usr/bin/env bash
# Local preview / build for the EvalHub showroom (Antora).
#
# Usage:
#   ./scripts/preview-local.sh              # start live preview (default)
#   ./scripts/preview-local.sh preview      # same as above
#   ./scripts/preview-local.sh build        # build static site into ./docs
#   ./scripts/preview-local.sh serve        # serve already-built ./docs
#   ./scripts/preview-local.sh stop         # stop preview container
#
# Environment:
#   PORT=8080                 HTTP port (default 8080)
#   PREVIEW_ENGINE=auto|podman|docker|npm
#                             auto = podman → docker → npm (default: auto)
#   OPEN_BROWSER=1            Open http://localhost:$PORT after start (macOS)
#   SELINUX=1                 Mount volume with :z for SELinux hosts
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PORT="${PORT:-8080}"
ENGINE="${PREVIEW_ENGINE:-auto}"
CONTAINER_NAME="${CONTAINER_NAME:-evalhub-showroom-antora}"
IMAGE="${ANTORA_VIEWER_IMAGE:-ghcr.io/juliaaano/antora-viewer}"
URL="http://localhost:${PORT}"

usage() {
  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

have() { command -v "$1" >/dev/null 2>&1; }

# Binary exists AND daemon/VM is reachable (macOS often has podman/docker installed but stopped).
runtime_ready() {
  local runtime="$1"
  have "$runtime" || return 1
  "$runtime" info >/dev/null 2>&1
}

resolve_engine() {
  case "$ENGINE" in
    podman|docker)
      if runtime_ready "$ENGINE"; then
        echo "$ENGINE"
        return
      fi
      echo "'$ENGINE' is installed but not reachable (daemon/VM stopped)." >&2
      if [[ "$ENGINE" == "podman" ]]; then
        echo "Try: podman machine start" >&2
      else
        echo "Try: start Docker Desktop" >&2
      fi
      if have npx; then
        echo "Falling back to npm..." >&2
        echo npm
        return
      fi
      exit 1
      ;;
    npm) echo npm; return ;;
    auto) ;;
    *)
      echo "Unknown PREVIEW_ENGINE='$ENGINE' (use auto|podman|docker|npm)" >&2
      exit 1
      ;;
  esac

  if runtime_ready podman; then
    echo podman
  elif runtime_ready docker; then
    echo docker
  elif have npx; then
    if have podman || have docker; then
      echo "Note: podman/docker installed but not running; using npm preview." >&2
    fi
    echo npm
  else
    echo "Need a running podman/docker, or Node.js (npx), to preview locally." >&2
    echo "  podman machine start   # if using Podman on macOS" >&2
    echo "  # or start Docker Desktop" >&2
    echo "  PREVIEW_ENGINE=npm $0 preview" >&2
    exit 1
  fi
}

volume_opts() {
  if [[ "${SELINUX:-0}" == "1" ]]; then
    echo "${ROOT}:/antora:z"
  else
    echo "${ROOT}:/antora"
  fi
}

stop_container() {
  local runtime="$1"
  if "$runtime" ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
    echo "Stopping container '$CONTAINER_NAME'..."
    "$runtime" rm -f "$CONTAINER_NAME" >/dev/null
    echo "Stopped."
  else
    echo "No container named '$CONTAINER_NAME' is running."
  fi
}

open_browser_maybe() {
  if [[ "${OPEN_BROWSER:-0}" == "1" ]] && have open; then
    (sleep 2; open "$URL") &
  fi
}

cmd_preview_container() {
  local runtime="$1"
  stop_container "$runtime" >/dev/null 2>&1 || true

  echo "Starting Antora live preview with $runtime"
  echo "  image : $IMAGE"
  echo "  root  : $ROOT"
  echo "  url   : $URL"
  echo
  echo "Press Ctrl+C to stop (or run: $0 stop)."
  echo

  open_browser_maybe
  # Interactive TTY when available; fall back for CI/non-TTY.
  local -a run_args=(run --rm --name "$CONTAINER_NAME" -v "$(volume_opts)" -p "${PORT}:8080")
  if [[ -t 0 && -t 1 ]]; then
    run_args+=(-i -t)
  fi
  exec "$runtime" "${run_args[@]}" "$IMAGE"
}

cmd_build_npm() {
  echo "Building Antora site with npx antora → ./docs"
  if [[ ! -d node_modules/antora ]]; then
    npm i antora --no-fund --no-audit
  fi
  npx antora default-site.yml
  echo
  echo "Build complete: ${ROOT}/docs/modules/main/index.html"
}

cmd_serve_npm() {
  if [[ ! -f docs/modules/main/index.html ]]; then
    echo "No built site found. Running build first..."
    cmd_build_npm
  fi
  echo "Serving ./docs at $URL"
  echo "Press Ctrl+C to stop."
  open_browser_maybe
  if have python3; then
    exec python3 -m http.server "$PORT" --directory docs
  elif have python; then
    (cd docs && exec python -m SimpleHTTPServer "$PORT")
  else
    echo "python3 required to serve ./docs without a container." >&2
    exit 1
  fi
}

cmd_preview() {
  local eng
  eng="$(resolve_engine)"
  case "$eng" in
    podman|docker) cmd_preview_container "$eng" ;;
    npm)
      cmd_build_npm
      cmd_serve_npm
      ;;
  esac
}

cmd_build() {
  local eng
  eng="$(resolve_engine)"
  case "$eng" in
    npm) cmd_build_npm ;;
    podman|docker)
      # One-shot build inside the viewer image is awkward; prefer npm for static build.
      if have npx; then
        ENGINE=npm cmd_build_npm
      else
        echo "Static build needs Node.js (npx). For live reload use: $0 preview" >&2
        exit 1
      fi
      ;;
  esac
}

cmd_serve() {
  local eng
  eng="$(resolve_engine)"
  case "$eng" in
    npm) cmd_serve_npm ;;
    podman|docker)
      if [[ ! -f docs/modules/main/index.html ]]; then
        if have npx; then
          ENGINE=npm cmd_build_npm
        else
          echo "No ./docs build and no npx available. Use: $0 preview" >&2
          exit 1
        fi
      fi
      echo "Serving ./docs via $eng python http.server on $URL"
      open_browser_maybe
      exec "$eng" run --rm --name "${CONTAINER_NAME}-serve" \
        -v "$(volume_opts)" -p "${PORT}:8080" \
        -w /antora/docs \
        docker.io/library/python:3.12-alpine \
        python -m http.server 8080
      ;;
  esac
}

cmd_stop() {
  if have podman; then stop_container podman; fi
  if have docker; then stop_container docker; fi
  if have docker && ! have podman; then :; fi
}

main() {
  local cmd="${1:-preview}"
  case "$cmd" in
    -h|--help|help) usage 0 ;;
    preview|start) cmd_preview ;;
    build) cmd_build ;;
    serve) cmd_serve ;;
    stop) cmd_stop ;;
    *)
      echo "Unknown command: $cmd" >&2
      usage 1
      ;;
  esac
}

main "$@"
