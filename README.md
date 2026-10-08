# Hardening Flask / PostgreSQL

## 1. Packages GHCR

- API : https://github.com/AdrienCambier1/tp-docker-m2/pkgs/container/tp-docker-m2-api
- PostgreSQL : https://github.com/AdrienCambier1/tp-docker-m2/pkgs/container/tp-docker-m2-db

```bash
docker pull ghcr.io/adriencambier1/tp-docker-m2-api:1.0.1
docker pull ghcr.io/adriencambier1/tp-docker-m2-db:1.0.1
```

Lancement et tests :

```bash
mkdir -p secrets && openssl rand -hex 32 > secrets/db_password.txt
API_IMAGE=ghcr.io/adriencambier1/tp-docker-m2-api:1.0.1 docker compose up -d --no-build --wait
docker compose run --rm --no-deps tests
```

## 2. Avant / Après

| Critère | API avant | API après | DB avant | DB après |
|---|---|---|---|---|
| Image | `python:3.10-slim` | Chainguard Python | `postgres:14-alpine` | Chainguard Postgres |
| Taille | 223 Mo | 122 Mo | 415 Mo | 540 Mo |
| Utilisateur | root | 65532 | root | 70 |
| Shell | oui | non | oui | oui (script d'init) |
| CVE Trivy | 185 (47 HIGH) | 0 | 47 (1 CRITICAL) | 0 |
| Efficience Dive | 97,4 % | 99,7 % | — | — |

## 3. Images de base

- **Chainguard Python** : runtime distroless sans shell, pip ni gestionnaire de paquets, non-root par défaut, 0 CVE (Google Distroless testé : 159 CVE Debian non corrigées).
- **Chainguard Postgres** : imposé par le sujet, 0 CVE.
- **Reproductibilité** : toutes les images (Dockerfile, Compose, outils CI) sont épinglées par digest SHA256 et les dépendances Python en `==`. La CI refuse un `FROM` sans digest.

## 4. Healthchecks sans shell

- **API** : `["CMD", "/usr/bin/python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:5000/health', timeout=3)"]` : Python et sa bibliothèque standard remplacent curl.
- **PostgreSQL** : `["CMD", "pg_isready", "-h", "127.0.0.1", "-U", "...", "-d", "..."]`.
- L'API attend la base (`depends_on: condition: service_healthy`). La base est sur un réseau interne sans port publié. Les services tournent en lecture seule, sans capabilities et avec `no-new-privileges`.

## 5. Remédiations

| Paquet | CVE | Correction |
|---|---|---|
| Werkzeug 2.3.3 | CVE-2024-34069 (HIGH) + 7 MEDIUM | 3.1.9 |
| Flask 2.3.2 | CVE-2026-27205 (LOW) | 3.1.3 |
| pytest 7.4.0 | CVE-2025-71176 (MEDIUM) | 9.1.1, hors image de production |
| psycopg2-binary | non épinglé | 2.9.13 |

- Gunicorn remplace le serveur de développement Flask.
- **Flake8** : écarts E302, W293, W292 et W391 corrigés.
- Le mot de passe est lu depuis un secret Docker et `/dbtest` ne renvoie plus le détail des erreurs.
- `.dockerignore` n'autorise que `app.py` et `requirements.txt`.

## 6. Chaîne CI/CD

`Flake8 + Hadolint → Build + Dive (≥ 80 %) → Trivy + Intégration → Release GHCR`

- **Permissions** : `permissions: {}` par défaut, seul `release` a `packages: write`, connexion par `GITHUB_TOKEN`.
- **Épinglage** : actions par SHA de commit, outils par digest (un tag peut être déplacé, pas un SHA).
- **SemVer** : le tag `vX.Y.Z` publie `X.Y.Z`, `X.Y`, `X` et `latest`. Un push sur `main` publie `edge` et `sha-<commit>`. Les pull requests ne publient rien.
- L'image publiée est celle qui a été scannée et testée, sans reconstruction.

## 7. Preuves

[CI v1.0.1](https://github.com/AdrienCambier1/tp-docker-m2/actions/runs/37775388411) : les 6 jobs sont verts, publication incluse.

```text
flake8 / hadolint : exit 0
dive    : efficiency 99.71 %, PASS
trivy   : API 0, requirements.txt 0, DB 0
compose : api healthy, db healthy
/health : {"status":"ok"}   /dbtest : {"db_connection":"successful"}
pytest  : 3 passed
```
