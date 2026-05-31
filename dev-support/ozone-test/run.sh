#!/usr/bin/env bash
# run.sh -- convenience wrapper for the HMS + Ozone test harness.
#   ./run.sh build           build the HMS image
#   ./run.sh up              docker compose up -d
#   ./run.sh down            docker compose down -v  (wipes volumes too)
#   ./run.sh smoke           run smoke-test-ozone.sh
#   ./run.sh status          docker compose ps + healthcheck summary
#   ./run.sh logs <svc>      tail logs for svc (hms|om|scm|datanode|postgres)
#   ./run.sh all             build + up + wait + smoke

set -euo pipefail
HARNESS_ROOT=$(cd "$(dirname "$0")" && pwd)
COMPOSE_FILE="$HARNESS_ROOT/compose/docker-compose.yml"

# load .env if present
if [ -f "$HARNESS_ROOT/.env" ]; then set -a; . "$HARNESS_ROOT/.env"; set +a; fi

compose() { docker compose -f "$COMPOSE_FILE" --project-directory "$HARNESS_ROOT/compose" "$@"; }

wait_hms_healthy() {
  local tries=60 ; local proj="${COMPOSE_PROJECT_NAME:-ozone-test}"
  echo "waiting for HMS to become healthy..."
  while (( tries-- )); do
    state=$(docker inspect -f '{{.State.Health.Status}}' "${proj}-hms-1" 2>/dev/null || echo "missing")
    case "$state" in
      healthy)  echo "  HMS healthy"; return 0 ;;
      unhealthy) echo "  HMS UNHEALTHY"; compose logs --tail=40 hms; return 1 ;;
      starting) printf '.'; sleep 5 ;;
      missing|*) sleep 3 ;;
    esac
  done
  echo
  echo "  HMS never became healthy"; compose logs --tail=60 hms; return 1
}

case "${1:-}" in
  build)
    "$HARNESS_ROOT/hms-image/build.sh"
    ;;
  up)
    compose up -d
    ;;
  down)
    compose down -v
    ;;
  smoke)
    "$HARNESS_ROOT/tests/smoke-test-ozone.sh"
    ;;
  status)
    compose ps
    echo
    for c in $(compose ps --format '{{.Name}}'); do
      state=$(docker inspect -f '{{.State.Status}} / {{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}' "$c")
      printf '  %-40s %s\n' "$c" "$state"
    done
    ;;
  logs)
    [ -z "${2:-}" ] && { echo "usage: $0 logs <service>" >&2; exit 2; }
    compose logs -f --tail=100 "$2"
    ;;
  all)
    "$HARNESS_ROOT/hms-image/build.sh"
    compose up -d
    wait_hms_healthy
    "$HARNESS_ROOT/tests/smoke-test-ozone.sh"
    ;;
  -h|--help|"")
    sed -n '2,12p' "$0"
    ;;
  *)
    echo "unknown subcommand: $1 (try -h)" >&2; exit 2
    ;;
esac
