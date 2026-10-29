# Hardening Flask / PostgreSQL

## 1. Packages GHCR

- API : https://github.com/AdrienCambier1/tp-docker-m2/pkgs/container/tp-docker-m2-api
- PostgreSQL : https://github.com/AdrienCambier1/tp-docker-m2/pkgs/container/tp-docker-m2-db

```bash
docker pull ghcr.io/adriencambier1/tp-docker-m2-api:2.0.0
docker pull ghcr.io/adriencambier1/tp-docker-m2-db:2.0.0
```

Lancement et tests :

```bash
mkdir -p secrets && openssl rand -hex 32 > secrets/db_password.txt
API_IMAGE=ghcr.io/adriencambier1/tp-docker-m2-api:2.0.0 docker compose up -d --no-build --wait
docker compose run --rm --no-deps tests
```

Build local (le jeton simulé `secrets/pip_token.txt` est obligatoire) :

```bash
printf 'ghp_%s' "$(openssl rand -hex 18)" > secrets/pip_token.txt
docker buildx bake -f docker-bake.hcl api-ci
```

## 2. Avant / Après

| Critère | API avant | API après | DB avant | DB après |
|---|---|---|---|---|
| Image | `python:3.10-slim` | Chainguard Python 3.15 | `postgres:14-alpine` | Chainguard Postgres 18 |
| Taille | 223 Mo | 127 Mo | 415 Mo | 540 Mo |
| Utilisateur | root | 65532 | root | 70 |
| Shell | oui | non | oui | oui (script d'init) |
| Architectures | amd64 | amd64 + arm64 | amd64 | amd64 + arm64 |
| CVE Trivy | 185 (47 HIGH) | 0 | 47 (1 CRITICAL) | 0 |
| Efficience Dive | 97,4 % | 99,7 % | — | — |

## 3. Images de base

- **Chainguard Python** : runtime distroless sans shell, pip ni gestionnaire de paquets, non-root par défaut, 0 CVE (Google Distroless testé : 159 CVE Debian non corrigées).
- **Chainguard Postgres** : imposé par le sujet, 0 CVE.
- **Reproductibilité** : images (Dockerfile, Compose, outils CI) et frontend `docker/dockerfile` épinglés par digest SHA256, dépendances Python en `==`. La CI refuse un `FROM` sans digest. Les digests sont remontés quand Trivy détecte une faille corrigée en amont (passage à Python 3.15 le 26/10).

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

`flake8 + hadolint → build (bake, Dive, fuite de secret) → supply-chain (SBOM, Trivy, Grype + VEX) → integration → release (multi-arch, signature, attestations) → verify`

| Job | Permissions |
|---|---|
| flake8, hadolint, build, supply-chain, integration | `contents: read` |
| release | `contents: read`, `packages: write`, `id-token: write` (OIDC Cosign) |
| verify | `packages: read` |

- `permissions: {}` par défaut, connexion GHCR par `GITHUB_TOKEN`, aucune étape en `continue-on-error`.
- **Épinglage** : actions par SHA de commit, outils (Hadolint, Trivy, Dive, Syft, Grype) par digest.
- **SemVer** : `vX.Y.Z` publie `X.Y.Z`, `X.Y`, `X` et `latest` ; `main` publie `edge` et `sha-<commit>` ; les pull requests ne publient rien.
- **Cosign sans clé** : pas de `cosign.pub`, l'identité OIDC du workflow est vérifiée (issuer `https://token.actions.githubusercontent.com`, identité `https://github.com/AdrienCambier1/tp-docker-m2/.github/workflows/ci-cd.yaml@refs/tags/v2.0.0`).

## 7. Preuves

[CI v2.0.0](https://github.com/AdrienCambier1/tp-docker-m2/actions/runs/40870238667) : les 7 jobs sont verts, publication, signature et vérification incluses.

```text
flake8 / hadolint : exit 0
dive      : efficiency 99.71 %, PASS
trivy     : API 0, requirements.txt 0, DB 0
grype     : 0 match, CVE-2026-114583 levée par VEX (not_affected)
compose   : api healthy, db healthy
/health   : {"status":"ok"}   /dbtest : {"db_connection":"successful"}
pytest    : 3 passed
```

## 8. Industrialisation BuildKit (étape 1)

**Cache pip** : `RUN --mount=type=cache` (hors couches) et `# syntax=docker/dockerfile:1.28.0` en tête du Dockerfile.

| Scénario (local, `bake api-ci`) | Durée | Paquets téléchargés |
|---|---|---|
| Build à froid (`docker builder prune -af`) | 10,7 s | 9 |
| Ajout d'une dépendance mineure, cache persistant | 3,8 s | 1 (les 9 autres « Using cached ») |
| Même modification avec le Dockerfile du TP1 (`--no-cache-dir`) | 4,9 s | 10 |
| Rebuild sans modification | 1,5 s | 0 |

En CI, le cache est importé et exporté en mode `max` (`type=gha`), un scope par cible.

**Secret de build** : `--mount=type=secret,id=pip_token,required=true`, monté en `tmpfs` le temps de l'instruction. Le build échoue si le secret est absent ou vide. Le jeton a le format GitHub PAT (`ghp_…`) pour être reconnaissable par Trivy.

```text
docker history --no-trunc        : 0 occurrence du jeton
docker export (fichiers finaux)  : 0 occurrence, aucun /run/secrets ni cache pip
docker save (toutes les couches) : 0 occurrence
trivy --scanners secret          : 0 secret
contrôle négatif (ARG + echo)    : jeton visible dans history, trivy : 3 x github-pat, exit 1
```

La CI échoue si le jeton apparaît dans `history`, `inspect` ou les couches. `secrets/` est ignoré par Git et exclu du contexte de build.

**Manifeste distant** :

```text
$ docker buildx imagetools inspect ghcr.io/adriencambier1/tp-docker-m2-api:2.0.0
MediaType: application/vnd.oci.image.index.v1+json
Digest:    sha256:50714e1ea6c44ba3084850733472f42cde465efb97b1497e1d434dd4897556c7
  ...@sha256:a28f859fbdfe58653e24377da57a2f5e47ef34a62cdf851aab8f6bd4e576a806  Platform: linux/amd64
  ...@sha256:65eb3c740854d0f421c920e9df6e1be4bd9dddd2033ea97bf50f13d49fa853dc  Platform: linux/arm64
  ...@sha256:388318a7fd28996f3ce63da455a267ad0473828ada47092b612dff2365d6c75f  Platform: unknown/unknown (provenance)
```

## 9. SBOM et gouvernance VEX (étape 2)

`sbom.cdx.json` (CycloneDX 1.7) et `sbom.spdx.json` (SPDX 2.3) sont les SBOM certifiés de `2.0.0` linux/amd64, générés par Syft sans exécuter le conteneur. Ils sont aussi archivés dans les artefacts CI `sbom` et `sbom-published`.

| Requête | Résultat |
|---|---|
| `jq '[.components[] \| select(.type != "file")] \| length' sbom.cdx.json` | 40 |
| `jq '.packages \| length' sbom.spdx.json` | 40 |
| `jq -r '[.components[] \| .purl // empty \| capture("^pkg:(?<t>[^/]+)/").t] \| group_by(.) \| map("\(.[0]): \(length)") \| .[]' sbom.cdx.json` | apk: 30, pypi: 9 |
| `jq -r '.components[] \| .purl // empty \| select(startswith("pkg:pypi"))' sbom.cdx.json` | blinker, click, flask, gunicorn, itsdangerous, jinja2, markupsafe, psycopg2-binary, werkzeug |
| `jq -r '[.components[] \| .licenses[]? \| .license.id // .license.name // .expression] \| unique \| .[]' sbom.cdx.json` | 13 licences : Apache-2.0, BSD-2-Clause, BSD-3-Clause, MIT, PSF-2.0, MPL-2.0 AND MIT, LGPL-2.1-or-later, GPL-3.0-or-later, … |

**Grype sur le SBOM** (`.grype.yaml`) : `grype sbom:sbom.cdx.json -c .grype.yaml` bloque dès le niveau HIGH et charge `security.vex.json`. Contrôle négatif : le SBOM de l'ancienne base Chainguard fait échouer le gate (CVE-2026-111497 CRITICAL, corrigeable).
`only-fixed` n'est pas activé : Grype appliquerait ce filtre avant le VEX, et la déclaration ne serait jamais la règle qui lève l'alerte. Le gate est donc plus strict que le minimum demandé : une faille HIGH non corrigée doit elle aussi être qualifiée par VEX. Trivy garde le seuil « corrigeable » (`--ignore-unfixed`).

**Déclaration VEX** (`security.vex.json`, OpenVEX 0.2.0) :

| CVE | Composant | Statut | Justification |
|---|---|---|---|
| CVE-2026-114583 (MEDIUM, sans correctif) | `pkg:apk/wolfi/python-3.15` | `not_affected` | `vulnerable_code_not_in_execute_path` |

La faille contourne `tarfile.tar_filter` lors d'un `extractall()`. Ni l'API ni ses dépendances n'importent `tarfile` (vérifié dans l'image : aucun fichier de `/app` ne le référence, et le module n'est pas chargé après `import app`). L'API n'expose que `/health`, `/hello` et `/dbtest`, sans téléversement de fichier, avec un système de fichiers en lecture seule et sans shell. Résultat dans Grype : `CVE-2026-114583 python-3.15 -> not_affected`. La déclaration sera revue quand Wolfi publiera le correctif.

## 10. Vérification publique

```text
Image  : ghcr.io/adriencambier1/tp-docker-m2-api:2.0.0
Index  : sha256:50714e1ea6c44ba3084850733472f42cde465efb97b1497e1d434dd4897556c7
amd64  : sha256:a28f859fbdfe58653e24377da57a2f5e47ef34a62cdf851aab8f6bd4e576a806
arm64  : sha256:65eb3c740854d0f421c920e9df6e1be4bd9dddd2033ea97bf50f13d49fa853dc
```

L'index et ses variantes sont signés (`cosign sign --recursive`). Chaque variante porte deux attestations signées : SBOM CycloneDX et SBOM SPDX. Avec Cosign ≥ 3 (ou `docker run --rm ghcr.io/sigstore/cosign/cosign:v3.1.4` à la place de `cosign`) :

```bash
IMG=ghcr.io/adriencambier1/tp-docker-m2-api
ID=https://github.com/AdrienCambier1/tp-docker-m2/.github/workflows/ci-cd.yaml@refs/tags/v2.0.0
ISS=https://token.actions.githubusercontent.com
```

```bash
cosign verify "$IMG@sha256:50714e1ea6c44ba3084850733472f42cde465efb97b1497e1d434dd4897556c7" --certificate-identity "$ID" --certificate-oidc-issuer "$ISS"
```

```bash
cosign verify-attestation "$IMG@sha256:a28f859fbdfe58653e24377da57a2f5e47ef34a62cdf851aab8f6bd4e576a806" --type cyclonedx --certificate-identity "$ID" --certificate-oidc-issuer "$ISS" > /dev/null
```

```bash
cosign verify-attestation "$IMG@sha256:a28f859fbdfe58653e24377da57a2f5e47ef34a62cdf851aab8f6bd4e576a806" --type cyclonedx --certificate-identity "$ID" --certificate-oidc-issuer "$ISS" | head -n 1 | jq -r .payload | base64 -d | jq .predicate > sbom-certifie.cdx.json
```

Remplacer le digest amd64 par celui d'arm64, ou `cyclonedx` par `spdxjson`, pour les autres attestations. Résultats obtenus :

```text
The cosign claims were validated
Existence of the claims in the transparency log was verified offline
The code-signing certificate was verified using trusted certificate authority certificates
attestation amd64 : predicateType https://cyclonedx.org/bom, sujet a28f859f…, 40 composants
attestation arm64 : predicateType https://cyclonedx.org/bom, sujet 65eb3c74…, 40 composants
identité incorrecte : exit 1
```
