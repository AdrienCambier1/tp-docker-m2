# Hardening Flask / PostgreSQL — Rapport technique

Microservice Flask + PostgreSQL durci : images distroless Chainguard épinglées par
digest, exécution non-root, Compose isolé, pipeline GitHub Actions bloquant
(Flake8 → Hadolint → Build/Dive → Trivy → Intégration → Release GHCR SemVer).

Le détail chronologique de toutes les étapes est dans [JOURNAL.md](JOURNAL.md).

```
.
├── app.py / test_app.py / pytest.ini
├── requirements.txt          # runtime (épinglé, 0 CVE)
├── requirements-dev.txt      # pytest, flake8
├── Dockerfile                # multi-stage : chainguard/python:latest-dev -> chainguard/python (distroless)
├── Dockerfile.test           # image pytest (+ Dockerfile.test.dockerignore)
├── docker-compose.yml        # api + db + tests (profil "test")
├── .dockerignore  .hadolint.yaml  .dive-ci  .flake8
├── .env.example              # surcharges optionnelles (utilisateur / base)
└── .github/workflows/ci-cd.yaml
```

---

## 1. Liens publics des packages GHCR

| Image | Package |
|-------|---------|
| API Flask | https://github.com/AdrienCambier1/tp-docker-m2/pkgs/container/tp-docker-m2-api |
| PostgreSQL | https://github.com/AdrienCambier1/tp-docker-m2/pkgs/container/tp-docker-m2-db |

> Les packages sont créés au premier passage du job `release`. Pour qu'ils soient
> publics : *Package settings → Change visibility → Public*.

Une version est publiée en poussant un tag SemVer :

```bash
git tag v1.0.0 && git push origin v1.0.0
```

Récupération et test :

```bash
docker pull ghcr.io/adriencambier1/tp-docker-m2-api:1.0.0
docker pull ghcr.io/adriencambier1/tp-docker-m2-db:1.0.0
```

```bash
mkdir -p secrets && openssl rand -base64 32 | tr -d '\n' > secrets/db_password.txt
API_IMAGE=ghcr.io/adriencambier1/tp-docker-m2-api:1.0.0 docker compose up -d --no-build --wait
curl http://127.0.0.1:5000/dbtest
```

Tags produits : `1.0.0`, `1.0`, `1`, `latest`, `sha-<commit>` pour un tag `v1.0.0` ;
`edge` et `sha-<commit>` pour un push sur `main`.

---

## 2. Tableau comparatif Avant / Après

| Critère | API avant | API après | DB avant | DB après |
|---------|-----------|-----------|----------|----------|
| Image | `python:3.10-slim` (tag mouvant) | `cgr.dev/chainguard/python@sha256:b624…` | `postgres:14-alpine` (tag mouvant) | `cgr.dev/chainguard/postgres@sha256:0c4e…` |
| Poids | 223 Mo | **128 Mo** (−43 %) | 415 Mo | 540 Mo ¹ |
| Utilisateur | root (UID 0) | **nonroot (65532)** | root puis `gosu` | **postgres (70)** dès le démarrage |
| Shell | oui (`sh`, `bash`, `apt`, `pip`) | **non** (ni `sh`, ni `ls`, ni `pip`, ni `apk`) | oui | oui ² |
| CVE Trivy (total) | 185 (47 HIGH) | **0** | 47 (1 CRITICAL, 22 HIGH) | **0** |
| CVE corrigeables HIGH/CRIT | 3 (+ 20 Python au total) | **0** | 22 | **0** |
| Efficience Dive | 97,36 % (5,7 Mo gaspillés) | **99,73 %** (237 ko) | — | — |
| Port exposé | 5000 sur toutes interfaces | `127.0.0.1:5000` | 5432 sur toutes interfaces | **aucun** (réseau interne) |
| Contenu `/app` | `.git`, tests, compose (mots de passe), Dockerfile… | `app.py` + dépendances | — | — |

¹ L'image Chainguard Postgres gratuite (`latest`) embarque PostgreSQL 18 complet
(extensions, outils client) : plus lourde, mais 0 CVE contre 47.
² Le script d'entrée officiel `docker-entrypoint.sh` (initdb, gestion des secrets
`_FILE`) nécessite bash ; la surface est compensée par `read_only`, `cap_drop: ALL`,
`no-new-privileges`, UID 70 et l'absence de port publié.

---

## 3. Justification des images de base

**API — Chainguard Python** (`cgr.dev/chainguard/python`), autorisée par le sujet
au même titre que Google Distroless. Les deux ont été mesurées :

| Base | Taille | CVE | Python |
|------|--------|-----|--------|
| `gcr.io/distroless/python3-debian13:nonroot` | 90,5 Mo | 159 (30 HIGH, non corrigées par Debian) | 3.13.5 |
| `cgr.dev/chainguard/python:latest` | 100,9 Mo | **0** | 3.14.8 |

Chainguard l'emporte : distroless (pas de shell, de gestionnaire de paquets ni de
coreutils), utilisateur `nonroot` par défaut, reconstruite quotidiennement sur
Wolfi → 0 CVE. Le builder `:latest-dev` est la même image + pip/shell : même
Python et même libc, donc wheels compatibles ABI.

**DB — Chainguard Postgres**, imposée par le sujet : 0 CVE contre 47 pour
`postgres:14-alpine` (dont 1 CRITICAL dans le binaire Go `gosu`).

**Immuabilité et reproductibilité**
- toutes les images (`FROM` du Dockerfile, `Dockerfile.test`, `image:` du compose,
  outils CI Hadolint/Trivy/Dive) sont **épinglées par digest SHA256** ; le tag
  (`latest`, seul tag gratuit chez Chainguard) n'est qu'indicatif, le digest fait foi ;
- un contrôle CI échoue si un `FROM` n'a pas de `@sha256:` (Hadolint ne le détecte pas) ;
- toutes les dépendances Python sont épinglées en `==` ;
- la mise à jour des digests est un acte explicite (commit revu), ce qui permet de
  suivre les nouvelles images Chainguard sans dérive silencieuse.

---

## 4. Résolution des contraintes sans shell

Dans une image distroless, `HEALTHCHECK CMD curl …` ou `CMD-SHELL` échouent : il
n'y a ni `/bin/sh` ni `curl`. Les sondes sont donc en **forme exec** et utilisent
ce que l'image contient déjà.

**API** (Dockerfile et compose) :
```yaml
test: ["CMD", "/usr/bin/python", "-c",
       "import sys, urllib.request; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:5000/health', timeout=3).status == 200 else 1)"]
```
L'interpréteur Python du runtime et `urllib` (bibliothèque standard) font une
requête HTTP sur `/health` ; toute exception (refus de connexion, timeout, 5xx)
donne un code de sortie ≠ 0.

**PostgreSQL** :
```yaml
test: ["CMD", "pg_isready", "-h", "127.0.0.1", "-U", "${POSTGRES_USER:-appuser}", "-d", "${POSTGRES_DB:-appdb}"]
```
`pg_isready`, client fourni par l'image, appelé directement (les variables sont
interpolées par Compose, pas par un shell).

**Synchronisation** : `depends_on: db: condition: service_healthy` (+ `restart: true`) —
l'API ne démarre qu'après la validation de la sonde PostgreSQL ; le service `tests`
attend lui-même que l'API soit `healthy`.

Autres adaptations au runtime minimal : `read_only: true` avec `tmpfs` pour `/tmp`
et le socket PostgreSQL, gunicorn avec `--worker-tmp-dir /dev/shm`,
`PYTHONDONTWRITEBYTECODE=1`, volume monté sur `/var/lib/postgresql` (propriété
UID 70 dans l'image) pour que `initdb` fonctionne sans capability `CHOWN`.

---

## 5. Journal des remédiations de dépendances & qualité

**Flake8** — le code passait la config d'équipe uniquement parce qu'elle ignore
`E302, W293, W292, W391`. Corrigé quand même : 2 lignes vides entre définitions
(8× E302), espaces sur ligne vide (W293), ligne vide finale (W391), saut de ligne
final manquant (W292), 2× E501 introduits puis corrigés. `flake8` et
`flake8 --isolated` sont vierges.

**Vulnérabilités du `requirements.txt` d'origine** (Trivy) :

| Paquet | Version | CVE | Sévérité |
|--------|---------|-----|----------|
| Werkzeug | 2.3.3 | CVE-2024-34069 | **HIGH** |
| Werkzeug | 2.3.3 | CVE-2023-46136, CVE-2024-49766, CVE-2024-49767, CVE-2025-66221, CVE-2026-21860, CVE-2026-27199, CVE-2026-102598 | MEDIUM |
| Flask | 2.3.2 | CVE-2026-27205 | LOW |
| pytest | 7.4.0 | CVE-2025-71176 | MEDIUM |
| psycopg2-binary | non épinglé | build non reproductible | — |

Plus, dans l'image `python:3.10-slim` : `wheel` (CVE-2026-24049, HIGH),
`jaraco.context` (CVE-2026-23949, HIGH), `pip` (7 CVE), `setuptools` (1 CVE).

**Montées de version** :
- `Flask 2.3.2 → 3.1.3` et `Werkzeug 2.3.3 → 3.1.9` : dernières versions, corrigent
  toutes les CVE ; aucune API dépréciée n'est utilisée par l'application ;
- `psycopg2-binary → ==2.9.13` : épinglé, wheel Python 3.14, compatible PostgreSQL 18 ;
- `pytest 7.4.0 → 9.1.1` déplacé dans `requirements-dev.txt` (hors production) ;
- ajout de `gunicorn==26.2.0` (serveur WSGI de production) ;
- `pip`, `setuptools`, `wheel` disparaissent de l'image finale (runtime sans pip).

Durcissements applicatifs : mot de passe lu depuis un secret fichier
(`DB_PASSWORD_FILE`), plus de mot de passe par défaut dans le code, `/dbtest`
ne renvoie plus le message d'exception au client, `connect_timeout=5`.

---

## 6. Sécurisation de la chaîne CI/CD

**Permissions minimales** : `permissions: {}` au niveau du workflow ; chaque job
reçoit `contents: read` ; seul `release` a `packages: write`. Connexion à GHCR
avec le `GITHUB_TOKEN` éphémère du workflow (aucun PAT stocké).
`persist-credentials: false` sur chaque checkout. Les pull requests ne publient rien.

**Pinning SHA** : chaque action est référencée par SHA de commit complet (version
en commentaire) — un tag Git peut être déplacé par un attaquant (cas de la
compromission des tags de `aquasecurity/trivy-action` en 2026), un SHA non.
Hadolint, Trivy et Dive tournent depuis des images Docker épinglées par digest.

**Barrières** : `flake8` ∥ `hadolint` → `build` (Dive ≥ 80 %) → `trivy` ∥
`integration` → `release`. Chaque étape échoue avec un code ≠ 0 ; `release`
dépend de tous les jobs. L'image publiée est l'artefact exact qui a été scanné et
testé (`docker save`/`docker load`, pas de rebuild).

**SemVer** (`docker/metadata-action`) : un tag `vX.Y.Z` publie `X.Y.Z`, `X.Y`,
`X` et `latest` (le tag majeur `0` est désactivé pour les versions `0.x`, instables par définition) ; chaque push sur `main`
publie `edge` + `sha-<commit>` pour la traçabilité. Les images restent tirables
par digest pour un déploiement immuable.

---

## 7. Preuves d'exécution

Sorties obtenues en local (Docker 29.8.2) ; les mêmes commandes tournent en CI.

**Flake8**
```
$ flake8 --config .flake8 .
$ echo $?
0
```

**Hadolint**
```
$ hadolint --config .hadolint.yaml Dockerfile Dockerfile.test
$ echo $?
0
```

**Dive**
```
$ CI=true dive tp-docker-m2-api:local --ci-config .dive-ci
  efficiency: 99.7266 %
  wastedBytes: 237208 bytes (237 kB)
  userWastedPercent: 0.4756 %
  PASS: highestUserWastedPercent
  SKIP: highestWastedBytes: rule disabled
  PASS: lowestEfficiency
Result:PASS [Total:3] [Passed:2] [Failed:0] [Warn:0] [Skipped:1]
```

**Trivy**
```
$ trivy image --scanners vuln,secret --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 tp-api:after
│ tp-api:after (wolfi 20230201)                               │   wolfi    │        0        │
│ app/site-packages/flask-3.1.3.dist-info/METADATA            │ python-pkg │        0        │
│ app/site-packages/werkzeug-3.1.9.dist-info/METADATA         │ python-pkg │        0        │
│ app/site-packages/psycopg2_binary-2.9.13.dist-info/METADATA │ python-pkg │        0        │
│ app/site-packages/gunicorn-26.2.0.dist-info/METADATA        │ python-pkg │        0        │
exit=0
$ trivy fs --scanners vuln,secret --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 .
│ requirements.txt │ pip │ 0 │
$ trivy image cgr.dev/chainguard/postgres@sha256:0c4e…   -> 0 vulnérabilité
```

**Compose — état sain**
```
$ docker compose up -d --wait --wait-timeout 120
 Container tp-docker-m2-db-1  Healthy
 Container tp-docker-m2-api-1 Healthy
$ docker compose ps
api   Up (healthy)   127.0.0.1:5000->5000/tcp
db    Up (healthy)
$ curl http://127.0.0.1:5000/health   {"status":"ok"}
$ curl http://127.0.0.1:5000/dbtest   {"db_connection":"successful"}
```

**Tests d'intégration**
```
$ docker compose --profile test run --rm tests
test_app.py::test_health PASSED                                          [ 33%]
test_app.py::test_hello PASSED                                           [ 66%]
test_app.py::test_dbtest PASSED                                          [100%]
============================== 3 passed in 0.22s ===============================
```

**Publication GHCR** : voir l'onglet *Actions* du dépôt (job `Release GHCR`) et
les packages listés en section 1.
