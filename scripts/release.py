#!/usr/bin/env python3
# =============================================================================
# Fichier     : scripts/release.py
# Rôle        : script d'automatisation de semantic-release, identique dans les
#               deux dépôts : écrit la nouvelle version dans les fichiers du
#               projet (package.json + package-lock.json pour Angular,
#               build.gradle pour Spring Boot) avant le commit de release.
# Usage       : python3 scripts/release.py <version>   (ex. 0.1.4)
# Codes       : 0 = version écrite | 1 = mauvais usage
#               2 = type de projet inconnu | 3 = version ou fichier invalide
# Utilisé par : .releaserc.yml (plugin @semantic-release/exec, étape prepare)
# =============================================================================
import json
import re
import sys
from pathlib import Path

# Version sémantique MAJEUR.MINEUR.CORRECTIF (+ suffixe facultatif, ex. -rc.1)
SEMVER = re.compile(r"^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$")
# Ligne de version de build.gradle, ex. : version = '0.2.4'
GRADLE_VERSION = re.compile(r"^version = '[^']*'$", re.MULTILINE)


def log(message):
    """Affiche un message préfixé, repérable dans les logs de la CI."""
    print(f"[release] {message}")


def fail(message, code):
    """Affiche l'erreur sur la sortie d'erreur et quitte avec le code donné."""
    print(f"[release] ERROR: {message}", file=sys.stderr)
    sys.exit(code)


def update_json(path, version):
    """Écrit la version dans un fichier JSON (package.json ou son lock)."""
    data = json.loads(path.read_text(encoding="utf-8"))
    old = data.get("version")
    data["version"] = version
    # package-lock.json répète la version du projet dans packages[""]
    if "" in data.get("packages", {}):
        data["packages"][""]["version"] = version
    # Indentation de 2 espaces et retour à la ligne final, comme npm
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n",
                    encoding="utf-8")
    log(f"{path.name}: {old} -> {version}")


def update_gradle(path, version):
    """Remplace la ligne "version = '...'" de build.gradle."""
    text = path.read_text(encoding="utf-8")
    match = GRADLE_VERSION.search(text)
    if not match:
        fail(f"no \"version = '...'\" line in {path.name}", 3)
    path.write_text(GRADLE_VERSION.sub(f"version = '{version}'", text, count=1),
                    encoding="utf-8")
    log(f"{path.name}: {match.group(0)} -> version = '{version}'")


def main():
    # Un seul argument attendu : la version calculée par semantic-release
    if len(sys.argv) != 2:
        fail("usage: release.py <version>", 1)
    version = sys.argv[1]
    if not SEMVER.match(version):
        fail(f"invalid semantic version: {version}", 3)

    # Même détection que run-tests.sh : fichiers "signatures" du projet
    root = Path.cwd()
    is_spring = ((root / "gradlew").is_file()
                 and (root / "build.gradle").is_file())
    is_angular = ((root / "package.json").is_file()
                  and (root / "angular.json").is_file())
    if is_spring:
        log("detected project type: spring-boot")
        update_gradle(root / "build.gradle", version)
    elif is_angular:
        log("detected project type: angular")
        update_json(root / "package.json", version)
        if (root / "package-lock.json").is_file():
            update_json(root / "package-lock.json", version)
    else:
        fail(f"unknown project type in {root}", 2)
    log(f"version {version} synchronised")


# Point d'entrée : exécuté seulement quand le fichier est lancé comme script
if __name__ == "__main__":
    main()
