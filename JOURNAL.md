# Journal de bord — TP noté « Hardening Flask / PostgreSQL »

Ce journal retrace, dans l'ordre chronologique, chaque étape réalisée, la
partie du sujet à laquelle elle correspond, les vulnérabilités trouvées
(Hadolint, Trivy, Dive, Flake8) et la manière dont elles ont été corrigées.

Outils utilisés en local : Docker 29.8.2, Hadolint 2.15.1, Trivy 0.75.0,
Dive 0.13.1, Flake8 7.4.1, pytest 9.1.1.

| # | Étape | Partie(s) du sujet |
|---|-------|--------------------|
| 0 | Audit initial de la stack héritée | Contexte, A, B, C, E, rapport §2 |
| 1 | Correction du code Python (Flake8) | A, rapport §5 |
| 2 | Assainissement de `requirements.txt` | E, livrable 3, rapport §5 |
| 3 | Politique Hadolint `.hadolint.yaml` | B, livrable 5 |
| 4 | Filtrage `.dockerignore` | D, livrable 4 |
| 5 | Dockerfile multi-stage durci | B, C, livrable 1 |
| 6 | Choix de l'image runtime (Distroless vs Chainguard) | C, E, rapport §3 |
| 7 | Audit Trivy + Dive de l'image finale | D, E |
| 8 | Compose durci, healthchecks sans shell, tests | F, livrable 2, rapport §4 |
| 9 | Pipeline GitHub Actions + publication GHCR | G, §5 Pipeline, livrable 7 |
| 10 | Rédaction du rapport `README.md` | livrable 6, §6 Rapport |

---

## Étape 0 — Audit initial de la stack héritée

> **Parties : Contexte (pièges à éradiquer), A, B, C, E — sert de colonne « Avant » au rapport §2**

Avant toute modification, j'ai mesuré l'existant pour avoir une base de comparaison.

### 0.1 Flake8 (Partie A)

```
$ flake8 .                 # avec .flake8 fourni
(aucune sortie, exit 0)
$ flake8 --isolated app.py test_app.py   # sans la config, pour voir ce qu'elle masque
app.py:13:1: E302 expected 2 blank lines, found 1     (x4)
app.py:46:1: W293 blank line contains whitespace
app.py:50:1: W391 blank line at end of file
test_app.py:4:1: E302 expected 2 blank lines, found 1 (x4)
test_app.py:23:58: W292 no newline at end of file
```

Constat : le code passe la configuration d'équipe, mais uniquement parce que
celle-ci ignore `E302, W293, W292, W391`. Ces écarts existent bien dans le code.

### 0.2 Hadolint (Partie B)

```
$ hadolint Dockerfile                          -> exit 0
$ hadolint --config .hadolint.yaml Dockerfile  -> exit 0   (après création de la politique, étape 3)
```

Constat important : **Hadolint ne voit rien** sur le Dockerfile d'origine, alors
qu'il est très mauvais. Raison : l'analyse est statique, et
- `DL3002` (root) ne se déclenche que si un `USER root` est **explicite** ; ici
  l'image tourne en root **implicitement** (aucun `USER`) ;
- `python:3.10-slim` est un tag considéré comme « versionné » alors qu'il est mouvant
  (il pointe vers une nouvelle image à chaque patch Debian/Python).

=> Hadolint seul ne suffit pas : j'ai ajouté un contrôle CI qui exige un digest
`@sha256:` sur chaque `FROM` (étape 9), et l'utilisateur non-root est vérifié à
l'exécution (étape 7).

### 0.3 Inspection de l'image d'origine (Parties C, D)

```
$ docker build -t tp-api:before .
$ docker run --rm --entrypoint sh tp-api:before -c 'id; which sh bash pip apt'
uid=0(root) gid=0(root) groups=0(root)
/usr/bin/sh  /usr/bin/bash  /usr/local/bin/pip  /usr/bin/apt
$ docker run --rm --entrypoint ls tp-api:before -la /app
.flake8  .git/  Dockerfile  LICENSE  app.py  docker-compose.yml  requirements.txt  test_app.py
```

Problèmes relevés :
- exécution en **root** ;
- présence d'un **shell**, de **pip** et d'**apt** dans l'image ;
- **`COPY . .` sans `.dockerignore`** : le dossier `.git` complet, les tests, le
  `docker-compose.yml` (qui contient les mots de passe) sont embarqués dans l'image ;
- `pytest` installé en production ; serveur de **développement** Flask (`app.run`).

### 0.4 Trivy sur l'image d'origine (Partie E)

```
$ trivy image tp-api:before
tp-api:before (debian 13.7)  165 vulnérabilités  (HIGH 44, MEDIUM 58, LOW 61, UNKNOWN 2)
Python (python-pkg)           20 vulnérabilités  (HIGH 3,  MEDIUM 15, LOW 2)  — toutes corrigeables
TOTAL : 185 CVE dont 47 HIGH
```

Vulnérabilités applicatives Python détectées :

| Paquet | Version | CVE | Sévérité | Corrigé en |
|--------|---------|-----|----------|-----------|
| Werkzeug | 2.3.3 | CVE-2024-34069 (exécution de code via le debugger) | **HIGH** | 3.0.3 |
| Werkzeug | 2.3.3 | CVE-2023-46136 (DoS multipart) | MEDIUM | 2.3.8 / 3.0.1 |
| Werkzeug | 2.3.3 | CVE-2024-49766 (`safe_join` Windows) | MEDIUM | 3.0.6 |
| Werkzeug | 2.3.3 | CVE-2024-49767 (épuisement de ressources) | MEDIUM | 3.0.6 |
| Werkzeug | 2.3.3 | CVE-2025-66221 (DoS noms de périphériques Windows) | MEDIUM | 3.1.4 |
| Werkzeug | 2.3.3 | CVE-2026-21860, CVE-2026-27199, CVE-2026-102598 (`safe_join`) | MEDIUM | 3.1.5 → 3.1.9 |
| Flask | 2.3.2 | CVE-2026-27205 (fuite d'info via cache de session) | LOW | 3.1.3 |
| pytest | 7.4.0 | CVE-2025-71176 | MEDIUM | 9.0.3 |
| wheel | 0.45.1 | CVE-2026-24049 | **HIGH** | 0.46.2 (outil de l'image de base) |
| jaraco.context | 5.3.0 | CVE-2026-23949 | **HIGH** | 6.1.0 (vendorisé dans setuptools) |
| pip | 23.0.1 | 7 CVE (CVE-2023-5752, CVE-2025-8869, …) | MEDIUM/LOW | 26.x (outil de l'image de base) |
| setuptools | 79.0.1 | CVE-2026-59890 | MEDIUM | 83.0.0 (outil de l'image de base) |

Autre défaut non détectable par Trivy : `psycopg2-binary` **non épinglé** (build non reproductible).

PostgreSQL d'origine (`postgres:14-alpine`, tag mouvant) :

```
$ trivy image postgres:14-alpine
alpine 3.24.2          : 1 MEDIUM
usr/local/bin/gosu (Go): 46 CVE — 1 CRITICAL, 21 HIGH, 21 MEDIUM, ...
```

### 0.5 Dive sur l'image d'origine (Partie D)

```
$ CI=true dive tp-api:before
efficiency: 97.3550 %   wastedBytes: 5.7 MB   userWastedPercent: 8.14 %
```

L'efficience passe déjà le seuil, mais 5,7 Mo sont gaspillés (fichiers apt/dpkg réécrits).

---

## Étape 1 — Correction du code Python

> **Partie A (Flake8) — rapport §5**

Corrections dans `app.py` et `test_app.py` (même les règles ignorées par `.flake8`,
pour que le code soit propre même en `--isolated`) :
- 2 lignes vides entre les définitions de haut niveau (E302/E305) ;
- suppression des espaces sur ligne vide (W293), de la ligne vide finale (W391) ;
- ajout du saut de ligne final (W292) ;
- imports triés (stdlib, puis tiers).

Durcissements applicatifs ajoutés (sans changer le comportement des routes) :
- `read_secret()` : le mot de passe est lu depuis `DB_PASSWORD_FILE` (Docker secret)
  et **plus aucun mot de passe par défaut n'est codé en dur** ;
- `/dbtest` ne renvoie plus `str(e)` au client (fuite d'informations internes :
  hôte, utilisateur…) ; l'erreur est journalisée côté serveur ;
- `connect_timeout=5` pour éviter qu'une requête reste bloquée.

Ajout de `pytest.ini` pour déclarer le marqueur `integration` (supprime le
`PytestUnknownMarkWarning`).

Un premier `flake8 --isolated` sur le code réécrit a relevé deux `E501`
(lignes de 80 et 83 caractères dans un docstring et un commentaire) : raccourcies.

```
$ flake8 .                                 -> exit 0
$ flake8 --isolated app.py test_app.py     -> exit 0
```

---

## Étape 2 — Assainissement de `requirements.txt`

> **Partie E (résolution des vulnérabilités Python) — livrable 3 — rapport §5**

| Avant | Après | Justification |
|-------|-------|---------------|
| `Flask==2.3.2` | `Flask==3.1.3` | corrige CVE-2026-27205 ; 3.1.x compatible avec l'API utilisée (`Flask`, `jsonify`, routes) |
| `Werkzeug==2.3.3` | `Werkzeug==3.1.9` | corrige les 8 CVE dont **CVE-2024-34069 (HIGH)** ; Flask 3.1 exige Werkzeug ≥ 3.1 |
| `pytest==7.4.0` | *déplacé* dans `requirements-dev.txt` en `9.1.1` | outil de test : n'a rien à faire en production ; corrige CVE-2025-71176 |
| `psycopg2-binary` (non épinglé) | `psycopg2-binary==2.9.13` | build reproductible ; wheel disponible pour Python 3.14 ; compatible PostgreSQL 18 |
| — | `gunicorn==26.2.0` | serveur WSGI de production à la place du serveur de dev Flask |

Les CVE de `pip`, `setuptools`, `wheel`, `jaraco.context` venaient de l'**image de base**
`python:3.10-slim` : elles disparaissent car l'image finale ne contient plus pip (étape 5/6).

Vérification :
```
$ trivy fs --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 .
requirements.txt │ pip │ 0
```

---

## Étape 3 — Politique Hadolint (`.hadolint.yaml`)

> **Partie B — livrable 5**

- `failure-threshold: warning` ;
- `trustedRegistries` : `docker.io`, `gcr.io`, `cgr.dev`, `ghcr.io` (règle DL3026) ;
- règles rehaussées en **error** :
  - `DL3002` : dernier `USER` ≠ root,
  - `DL3006` / `DL3007` : tag explicite, interdiction de `latest`,
  - `DL4006` : `SHELL ["/bin/bash", "-o", "pipefail", "-c"]` avant un pipe ;
- règles standards listées explicitement (bloquantes via le seuil warning) :
  `DL3025` (CMD JSON), `DL3042` (`--no-cache-dir`), `DL3020` (COPY au lieu de ADD),
  `DL3021`, `DL3022` (`COPY --from` sur un étage défini), `DL3003` (WORKDIR au lieu de cd),
  `SC2086` (guillemets), `SC2164` (`cd || exit`).

**Test de la politique** sur un Dockerfile volontairement fautif :

```
Dockerfile.bad:1 DL3026 error: Use only an allowed registry in the FROM image      (quay.io)
Dockerfile.bad:2 DL3007 error: Using latest is prone to errors ...
Dockerfile.bad:3 DL3006 error: Always tag the version of an image explicitly
Dockerfile.bad:4 DL3020 warning: Use COPY instead of ADD
Dockerfile.bad:5 DL3003 warning: Use WORKDIR to switch to a directory
Dockerfile.bad:5 DL3042 warning: Avoid use of cache directory with pip
Dockerfile.bad:6 DL4006 error: Set the SHELL option -o pipefail before RUN with a pipe
Dockerfile.bad:7 DL3022 warning: `COPY --from` should reference a previously defined `FROM` alias
Dockerfile.bad:8 DL3002 error: Last USER should not be root
Dockerfile.bad:9 DL3025 warning: Use arguments JSON notation for CMD and ENTRYPOINT
exit=1
```

Toutes les règles exigées par le sujet sont bien actives et bloquantes.

---

## Étape 4 — Filtrage du contexte de build (`.dockerignore`)

> **Partie D — livrable 4**

Stratégie **liste blanche** : `*` exclut tout, puis seuls `app.py` et
`requirements.txt` sont ré-autorisés. Les exclusions explicites (Git, `.env*`,
clés, `secrets/`, `__pycache__`, `*.pyc`, caches pytest/mypy, tests, outils
qualité, Dockerfiles, compose, docs, logs, archives) sont conservées en défense
en profondeur si la liste blanche s'élargit un jour.

L'image de tests utilise son propre filtre `Dockerfile.test.dockerignore`
(fonction BuildKit `<Dockerfile>.dockerignore`), qui n'autorise que le code, les
tests et les manifestes.

Vérification : l'image finale ne contient plus que `/app/app.py` et
`/app/site-packages` (cf. étape 7).

---

## Étape 5 — Dockerfile multi-stage durci

> **Parties B et C — livrable 1**

Structure :
1. **`builder`** : image `-dev` (avec pip), `WORKDIR /build`, copie de
   `requirements.txt` **seul** puis `pip install --no-cache-dir --target=/build/install`
   (cache de couche préservé quand seul `app.py` change), suppression de `bin/`,
   puis copie de `app.py`.
2. **`runtime`** : image sans shell, `COPY --from=builder /build/install /app/site-packages`
   et `COPY --from=builder /build/app.py /app/app.py` (chemins d'origine explicites),
   `USER 65532:65532`, `HEALTHCHECK` en forme exec Python, `ENTRYPOINT`/`CMD` en JSON
   lançant **gunicorn**.

Points de conformité :
- aucune ligne `RUN` dans le runtime (il n'y a de toute façon pas de shell) ;
- aucun cache pip (`--no-cache-dir` + `PIP_NO_CACHE_DIR=1`), aucun en-tête de
  compilation ni outil de build dans le runtime ;
- fichiers applicatifs propriété de root, lecture seule pour l'UID 65532 ;
- `PYTHONDONTWRITEBYTECODE=1` (compatible `read_only`), `PYTHONUNBUFFERED=1` (logs).

```
$ hadolint --config .hadolint.yaml Dockerfile Dockerfile.test  -> exit 0
```

---

## Étape 6 — Choix de l'image runtime : Google Distroless vs Chainguard

> **Parties C et E — rapport §3**

Première implémentation avec **Google Distroless** (`gcr.io/distroless/python3-debian13:nonroot`,
builder `python:3.13-slim-trixie` pour avoir la même ABI Python 3.13) :

```
taille : 117 Mo  | user : 65532 | shell : non | Dive : 99,79 %
Trivy  : debian 13.7 → 159 CVE (30 HIGH, 74 MEDIUM, 53 LOW) — 0 corrigeable
         Python      → 0
```

Le gate Trivy (`--ignore-unfixed`) passait, mais il restait 159 CVE **non corrigées
par Debian** (libssl, libc, python3.13 du paquet Debian…).

Comparaison des bases :

| Image de base | Taille | CVE totales | HIGH/CRIT corrigeables |
|---------------|--------|-------------|------------------------|
| `gcr.io/distroless/python3-debian13:nonroot` | 90,5 Mo | 159 | 0 |
| `cgr.dev/chainguard/python:latest` | 100,9 Mo | **0** | 0 |

**Décision (validée avec le binôme) : Chainguard Python**, également distroless
(pas de shell, ni `apk`, ni pip, ni même `ls`), reconstruite quotidiennement sur
Wolfi, avec **0 CVE**. Le builder devient `cgr.dev/chainguard/python:latest-dev`
(même Python 3.14.8, même libc → wheels compatibles).

Chainguard ne publie gratuitement que `latest` / `latest-dev` (tags mouvants) :
ils sont **neutralisés par l'épinglage digest** `@sha256:…`, seul le digest fait foi.

---

## Étape 7 — Audit Trivy + Dive de l'image finale

> **Parties C, D, E**

```
$ docker image inspect tp-api:after  -> 128 Mo, User=65532:65532
$ docker run --rm --entrypoint sh tp-api:after
exec: "sh": executable file not found in $PATH
$ docker run --rm --entrypoint /usr/bin/python tp-api:after -c "..."
uid=65532 ; which sh/bash/ls/pip/apk -> None ; /app = ['app.py', 'site-packages']

$ trivy image tp-api:after
tp-api:after (wolfi)  0
Python                0
$ trivy image --scanners vuln,secret --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 tp-api:after
-> exit 0

$ CI=true dive tp-api:after --ci-config .dive-ci
efficiency: 99.7266 %   wastedBytes: 237 kB   userWastedPercent: 0.48 %
Result: PASS
```

Le fichier `.dive-ci` fixe `lowestEfficiency: 0.80` et `highestUserWastedPercent: 0.10`.

---

## Étape 8 — Docker Compose durci, healthchecks sans shell, tests

> **Partie F — livrable 2 — rapport §4**

### Durcissement appliqué

| Mesure | API | DB |
|--------|-----|----|
| Image | build local / GHCR | Chainguard Postgres **épinglé par digest** |
| Utilisateur | `65532:65532` | `70:70` (postgres) |
| `read_only: true` + `tmpfs` | `/tmp` | `/var/run/postgresql`, `/tmp` |
| `cap_drop: [ALL]` | oui | oui |
| `no-new-privileges` | oui | oui |
| Limites | 256 Mo, 0,5 CPU, 100 PIDs | 512 Mo, 200 PIDs |
| Réseau | `frontend` + `backend` | `backend` **interne** uniquement |
| Port publié | `127.0.0.1:5000` | **aucun** (avant : `5432` ouvert sur toutes les interfaces) |
| Secret | `DB_PASSWORD_FILE=/run/secrets/db_password` | `POSTGRES_PASSWORD_FILE` |

Le mot de passe n'est plus en clair dans le compose : il vient de
`secrets/db_password.txt` (ignoré par Git, généré aléatoirement en local et en CI).

### Problèmes rencontrés et corrections

1. **Secret de type `environment` refusé** :
   `cannot create secret "tp-docker-m2_db_password" in read-only service db: 'file' is the sole supported option`
   → passage à un secret de type `file`.
2. **initdb en échec** : `chmod: /var/lib/postgresql/data: Operation not permitted`.
   Le volume nommé était créé avec un dossier appartenant à root, et le conteneur
   tourne en UID 70 sans capability. Dans l'image Chainguard, `/var/lib/postgresql`
   appartient à l'UID 70 → le volume est monté **sur le parent** `/var/lib/postgresql`,
   il hérite de la propriété UID 70 et `initdb` crée lui-même `PGDATA`.

### Healthchecks sans shell

- **API** : `["CMD", "/usr/bin/python", "-c", "import sys, urllib.request; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:5000/health', timeout=3).status == 200 else 1)"]`
  → utilise l'interpréteur présent dans l'image et sa stdlib (pas de curl/wget/sh).
- **DB** : `["CMD", "pg_isready", "-h", "127.0.0.1", "-U", "appuser", "-d", "appdb"]`
  → utilitaire client livré avec l'image, en forme exec.
- `depends_on: db: condition: service_healthy` (+ `restart: true`) : l'API ne
  démarre qu'une fois PostgreSQL réellement prêt.

### Tests d'intégration

Service `tests` (profil `test`) construit depuis `Dockerfile.test`, connecté
**uniquement** au réseau `backend` interne.

```
$ docker compose up -d --build --wait --wait-timeout 120
 Container tp-docker-m2-db-1  Healthy
 Container tp-docker-m2-api-1 Healthy
$ docker compose ps
api   Up (healthy)    127.0.0.1:5000->5000/tcp
db    Up (healthy)    (aucun port)
$ curl http://127.0.0.1:5000/health  -> {"status":"ok"} [200]
$ curl http://127.0.0.1:5000/hello   -> {"message":"Hello world"} [200]
$ curl http://127.0.0.1:5000/dbtest  -> {"db_connection":"successful"} [200]
$ docker compose --profile test run --rm --build tests
test_app.py::test_health PASSED
test_app.py::test_hello PASSED
test_app.py::test_dbtest PASSED
3 passed in 0.22s
$ docker compose exec db id      -> uid=70(postgres) gid=70(postgres)
$ docker compose top api         -> UID 65532 (gunicorn master + workers)
```

---

## Étape 9 — Pipeline GitHub Actions et publication GHCR

> **Partie G et section 5 (Pipeline CI/CD) — livrable 7**

Fichier : `.github/workflows/ci-cd.yaml`, déclenché sur `push`/`pull_request` vers
`main` et sur les tags `v*.*.*`.

| Job | Rôle | Dépend de |
|-----|------|-----------|
| `flake8` | `flake8 --config .flake8 .` | — |
| `hadolint` | Hadolint (conteneur épinglé) + contrôle « tous les FROM ont un digest » | — |
| `build` | Build BuildKit (cache GHA), **Dive** (`.dive-ci`, ≥ 80 %), export de l'image en artefact | flake8, hadolint |
| `trivy` | Trivy image API + `fs` (requirements) + image Postgres, `--exit-code 1` HIGH/CRITICAL | build |
| `integration` | secret éphémère, `compose up --wait --wait-timeout 120`, curl `/health` `/dbtest`, pytest, teardown `down -v` en `always()` | build |
| `release` | push GHCR des tags SemVer, uniquement sur `push` et si **tous** les jobs sont verts | tous |

Sécurité de la chaîne :
- `permissions: {}` au niveau global, `contents: read` par job, `packages: write`
  **uniquement** sur `release` ;
- authentification GHCR via `secrets.GITHUB_TOKEN` (aucun PAT) ;
- toutes les actions épinglées par **SHA de commit** (avec la version en commentaire),
  et les outils (Hadolint, Trivy, Dive) lancés via des images **épinglées par digest** ;
- `persist-credentials: false` sur les checkouts ;
- l'image publiée est **exactement celle** qui a été scannée et testée (artefact
  `docker save`/`docker load`, pas de rebuild).

Tags SemVer (docker/metadata-action) pour un tag Git `v1.2.3` :
`1.2.3`, `1.2`, `1`, `latest`, `sha-<court>` ; sur `main` : `edge`, `sha-<court>`.
L'image PostgreSQL Chainguard est republiée sur GHCR (`-db`) avec les mêmes tags via
`docker buildx imagetools create` (copie du digest, sans rebuild).

Vérification locale :
```
$ actionlint                -> exit 0
$ hadolint (conteneur)      -> exit 0
$ trivy fs (conteneur)      -> requirements.txt : 0
```

---

## Étape 10 — Rapport technique

> **Livrable 6 — section 6 du sujet**

Le `README.md` reprend la structure imposée (liens GHCR, tableau avant/après,
justification des images, healthchecks sans shell, remédiations, sécurisation
CI/CD, preuves d'exécution).
