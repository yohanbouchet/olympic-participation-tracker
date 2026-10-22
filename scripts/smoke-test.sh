#!/usr/bin/env bash
# =============================================================================
# Fichier     : scripts/smoke-test.sh
# Rôle        : test de démarrage ("smoke test") d'une image Docker, identique
#               dans les deux dépôts : lance le conteneur et vérifie qu'il
#               répond en HTTP AVANT que la CI publie l'image dans le registre.
#               API : démarre aussi un PostgreSQL temporaire (mot de passe
#               aléatoire, supprimé à la fin).
# Usage       : ./scripts/smoke-test.sh <image> [postgres]
#               (2e argument "postgres" : image de base de données)
# Codes       : 0 = l'image répond | 1 = l'image ne répond pas
#               2 = type de projet inconnu
# Utilisé par : .gitlab-ci.yml (job build:image), ou à la main en local
# =============================================================================

# Mode strict : arrêt sur erreur, sur variable inconnue, erreurs dans les "|"
set -euo pipefail

# Image à tester (argument obligatoire) et réseau Docker propre à ce test
# ($$ = numéro du processus, pour un nom unique)
readonly IMAGE="${1:?usage: smoke-test.sh <image>}"
readonly NET="smoke-net-$$"
# Type d'image : "postgres" si demandé, sinon déduit des fichiers du projet
readonly KIND="${2:-app}"

log()  { echo "[smoke-test] $*"; }
fail() { echo "[smoke-test] ERROR: $1" >&2; exit "${2:-1}"; }

# Nettoyage GARANTI à la sortie, même en cas d'erreur (trap ... EXIT)
cleanup() {
  docker rm -f smoke-app smoke-db >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Interroge l'URL depuis l'INTÉRIEUR du conteneur (aucun port publié sur la
# machine) : jusqu'à 60 essais espacés de 2 s
wait_for_http() {
  local url="$1" tries="${2:-60}"
  for _ in $(seq 1 "${tries}"); do
    if docker exec smoke-app wget -q -O /dev/null "${url}" 2>/dev/null; then
      return 0
    fi
    # Conteneur arrêté : inutile d'attendre davantage
    running="$(docker inspect -f '{{.State.Running}}' smoke-app)"
    [[ "${running}" == "true" ]] || return 1
    sleep 2
  done
  return 1
}

docker network create "${NET}" >/dev/null

# Image PostgreSQL : démarre-t-elle SANS root et accepte-t-elle les connexions ?
if [[ "${KIND}" == "postgres" ]]; then
  log "image type: postgres (database)"
  db_password="$(head -c 18 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  docker run -d --name smoke-app --network "${NET}" \
    -e POSTGRES_PASSWORD="${db_password}" "${IMAGE}" >/dev/null
  for _ in $(seq 1 30); do
    docker exec smoke-app pg_isready -U postgres >/dev/null 2>&1 && break
    sleep 2
  done
  if ! docker exec smoke-app pg_isready -U postgres >/dev/null 2>&1; then
    docker logs smoke-app 2>&1 | tail -20
    fail "image ${IMAGE} did not accept connections" 1
  fi
  [[ "$(docker exec smoke-app id -u)" != "0" ]] \
    || fail "image ${IMAGE} runs as root" 1
  log "image ${IMAGE} is working (non-root PostgreSQL)"
  exit 0
fi

# Même détection que run-tests.sh : fichiers "signatures" du projet
if [[ -f gradlew && -f build.gradle ]]; then
  log "project type: spring-boot (API + temporary PostgreSQL)"
  # Mot de passe aléatoire, jamais affiché ni réutilisé
  db_password="$(head -c 18 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  docker run -d --name smoke-db --network "${NET}" \
    -e POSTGRES_DB=smokedb -e POSTGRES_USER=smoke \
    -e POSTGRES_PASSWORD="${db_password}" postgres:18-alpine >/dev/null
  # Comme le healthcheck du compose : on attend que la base soit PRÊTE
  for _ in $(seq 1 30); do
    docker exec smoke-db pg_isready -U smoke -d smokedb >/dev/null 2>&1 && break
    sleep 2
  done
  docker exec smoke-db pg_isready -U smoke -d smokedb >/dev/null \
    || fail "temporary PostgreSQL did not start" 1
  docker run -d --name smoke-app --network "${NET}" \
    -e SPRING_DATASOURCE_URL=jdbc:postgresql://smoke-db:5432/smokedb \
    -e SPRING_DATASOURCE_USERNAME=smoke \
    -e SPRING_DATASOURCE_PASSWORD="${db_password}" "${IMAGE}" >/dev/null
  url="http://127.0.0.1:8080/api/notions"
elif [[ -f package.json && -f angular.json ]]; then
  log "project type: angular (Nginx)"
  docker run -d --name smoke-app --network "${NET}" \
    "${IMAGE}" >/dev/null
  # 127.0.0.1 et non "localhost" : Nginx n'écoute qu'en IPv4
  url="http://127.0.0.1:80/"
else
  fail "unknown project type in $(pwd)" 2
fi

# Verdict : en cas d'échec, on affiche la fin des logs pour comprendre
log "waiting for ${url}"
if wait_for_http "${url}"; then
  log "image ${IMAGE} is working"
else
  docker logs smoke-app 2>&1 | tail -20
  fail "image ${IMAGE} did not answer on ${url}" 1
fi
