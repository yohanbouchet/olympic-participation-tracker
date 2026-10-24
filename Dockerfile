# =============================================================================
# Fichier     : Dockerfile
# Rôle        : construire l'image du front Angular
#               (Olympic Participation Tracker)
#               en deux étages : compilation avec Node, puis service avec Nginx
# Utilise     : package.json, package-lock.json, src/, nginx/nginx.conf
# Utilisé par : docker-compose.yml (exercice 1),
#               pipeline GitLab CI (exercice 2)
# =============================================================================

# ---------- Étage 1 : construction (l'atelier) ----------
# Node 24 LTS, supporté jusqu'au 30/04/2028 (endoflife.date)
FROM node:24-alpine AS build
WORKDIR /build

# Dépendances d'abord : cette couche reste en cache tant qu'elles ne
# changent pas
COPY package.json package-lock.json ./
RUN npm ci

# Puis le code, et la compilation → /build/dist/olympic-games-starter/browser/
COPY . .
RUN npm run build

# ---------- Étage 2 : service (la vitrine) ----------
# Nginx 1.30, branche stable supportée (la 1.27 du README est en fin de vie)
FROM nginx:1.30-alpine

# Sécurité : applique les correctifs Alpine publiés depuis la sortie de
# l'image officielle (même version d'Alpine, correctifs seulement)
RUN apk upgrade --no-cache

# Configuration fournie par le dépôt : sert le dossier /app sur le port 80
COPY nginx/nginx.conf /etc/nginx/nginx.conf

# On ne récupère QUE le site compilé, donné à l'utilisateur nginx
# (uid/gid 101 dans l'image officielle)
COPY --from=build --chown=101:101 \
     /build/dist/olympic-games-starter/browser /app

# Sécurité : le serveur ne tourne pas en root. Numéro plutôt que nom :
# Kubernetes (runAsNonRoot) ne sait vérifier qu'un uid numérique
USER 101:101

# Documentation : le conteneur écoute sur le port 80
EXPOSE 80
