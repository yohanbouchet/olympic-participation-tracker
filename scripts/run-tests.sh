#!/usr/bin/env bash
# =============================================================================
# Fichier     : scripts/run-tests.sh
# Rôle        : script de tests UNIFIÉ, identique dans les deux dépôts.
#               Détecte le type de projet (Spring Boot ou Angular), vérifie
#               les outils, nettoie les anciens rapports, lance les tests et
#               range le rapport JUnit XML dans test-results/ (lu par la CI).
# Usage       : ./scripts/run-tests.sh [dossier_du_projet]
#               (sans argument : dossier courant)
# Codes       : 0 = tests OK | 1+ = tests en échec (code de Gradle/npm)
#               2 = type de projet inconnu | 3 = outil manquant
#               4 = aucun rapport JUnit produit
# Utilisé par : .gitlab-ci.yml (job de test), ou à la main en local
# =============================================================================

# Mode strict : arrêt sur erreur, sur variable inconnue, et erreurs visibles
# même au milieu d'un "|"
set -euo pipefail

# Dossier des rapports attendu par l'énoncé et par le pipeline
readonly RESULTS_DIR="test-results"

# Affichage : messages préfixés pour les repérer dans les logs de la CI ;
# fail "message" [code] écrit sur la sortie d'erreur et quitte
# (code 1 par défaut)
log()  { echo "[run-tests] $*"; }
fail() { echo "[run-tests] ERROR: $1" >&2; exit "${2:-1}"; }

# ---------- 1. Détection du type de projet ----------
# On se place dans le dossier donné en argument (ou on reste dans le courant)
cd "${1:-.}"

# Fichiers "signatures" : deux par type pour éviter les faux positifs
if [[ -f gradlew && -f build.gradle ]]; then
  project_type="spring-boot"
elif [[ -f package.json && -f angular.json ]]; then
  project_type="angular"
else
  msg="unknown project type in $(pwd)"
  msg+=" (no gradlew/build.gradle nor package.json/angular.json)"
  fail "${msg}" 2
fi
log "detected project type: ${project_type}"

# ---------- 2. Outils et nettoyage ----------
# require <commande> : quitte avec le code 3 si l'outil n'est pas installé
require() {
  command -v "$1" >/dev/null 2>&1 || fail "missing dependency: $1" 3
}

# Les rapports d'un lancement précédent ne doivent jamais être relus
log "cleaning previous test artifacts"
rm -rf "${RESULTS_DIR}"
mkdir -p "${RESULTS_DIR}"

# ---------- 3. Lancement des tests selon le type ----------
# "|| status=$?" : on MÉMORISE un échec au lieu de laisser set -e tout
# arrêter, pour pouvoir quand même copier le rapport (utile surtout en cas
# d'échec)
status=0
case "${project_type}" in
  spring-boot)
    require java
    [[ -x gradlew ]] || fail "gradlew is not executable" 3
    rm -rf build/test-results
    ./gradlew --no-daemon clean test || status=$?
    # Emplacement des rapports JUnit de Gradle (cf. README)
    report_src="build/test-results/test"
    ;;
  angular)
    require node
    require npm
    # Karma lance Chrome sans fenêtre : CHROME_BIN indique où il se trouve
    # (défini par la CI, sinon recherché parmi les noms habituels)
    if [[ -z "${CHROME_BIN:-}" ]]; then
      CHROME_BIN="$(command -v chromium \
                 || command -v chromium-browser \
                 || command -v google-chrome \
                 || true)"
      export CHROME_BIN
    fi
    [[ -n "${CHROME_BIN}" ]] \
      || fail "missing dependency: Chrome/Chromium (set CHROME_BIN)" 3
    # Dépendances absentes → installation reproductible (recommandée en CI)
    if [[ ! -d node_modules ]]; then
      log "node_modules not found, running npm ci"
      npm ci
    fi
    rm -rf reports
    npm test || status=$?
    # Emplacement des rapports JUnit de Karma (cf. karma.conf.js)
    report_src="reports"
    ;;
esac

# ---------- 4. Rapport et verdict ----------
# Copie des rapports XML dans test-results/, que les tests aient réussi ou non
if compgen -G "${report_src}/*.xml" >/dev/null; then
  cp "${report_src}"/*.xml "${RESULTS_DIR}/"
  report_count="$(find "${RESULTS_DIR}" -name "*.xml" | wc -l)"
  log "JUnit report(s) copied to ${RESULTS_DIR}/: ${report_count} file(s)"
else
  log "no JUnit report found in ${report_src}/"
  # Aucun rapport alors que tout "a réussi" : anomalie, on ne passe pas au vert
  [[ ${status} -ne 0 ]] || status=4
fi

# Le code de sortie final est le verdict lu par GitLab (0 = vert)
if [[ ${status} -eq 0 ]]; then
  log "tests PASSED"
else
  log "tests FAILED (exit code ${status})"
fi
exit "${status}"
