# Hardening Flask / PostgreSQL

Le projet contient une API Flask, une base PostgreSQL et les contrôles demandés
par le sujet. Un seul Dockerfile construit l'API ; Compose démarre deux services.
Les tests pytest fournis utilisent le client Flask et tournent dans un conteneur
temporaire du profil `test`, connecté à la même base. Ce conteneur ne nécessite
pas de Dockerfile supplémentaire.

## 1. Packages publics et lancement

Les deux packages sont publics :

- [API Flask](https://github.com/AdrienCambier1/tp-docker-m2/pkgs/container/tp-docker-m2-api)
- [PostgreSQL](https://github.com/AdrienCambier1/tp-docker-m2/pkgs/container/tp-docker-m2-db)

Commandes pour récupérer la version déjà publiée :

```powershell
docker pull ghcr.io/adriencambier1/tp-docker-m2-api:1.0.1
docker pull ghcr.io/adriencambier1/tp-docker-m2-db:1.0.1
```

La version `1.0.1` correspond au code décrit dans ce README. Prérequis de lancement : Docker avec
des conteneurs Linux. Python, pytest et PostgreSQL sont exécutés dans les conteneurs.

Depuis la racine du dépôt, dans PowerShell :

```powershell
New-Item -ItemType Directory -Force secrets | Out-Null
if (!(Test-Path secrets/db_password.txt)) {
    $secretBytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($secretBytes)
    $rng.Dispose()
    [IO.File]::WriteAllText("$PWD/secrets/db_password.txt", [Convert]::ToBase64String($secretBytes))
}
docker compose up -d --build --wait --wait-timeout 120
docker compose run --rm --no-deps tests
```

Les routes sont `/health`, `/hello` et `/dbtest`, sur `http://127.0.0.1:5000`.
`docker compose up` démarre seulement l'API et la base. La commande `run tests`
active ponctuellement le profil `test` et supprime le conteneur après les tests.
`pytest.ini` déclare le marqueur `integration` utilisé dans le fichier fourni.
Pour arrêter les services : `docker compose down`. Le volume conserve les données.

Les valeurs `POSTGRES_DB` et `POSTGRES_USER` ont des valeurs par défaut dans
Compose ; elles peuvent être surchargées par les variables d'environnement ou un
fichier `.env` facultatif. Le mot de passe est dans
`secrets/db_password.txt`, ignoré par Git et exclu du contexte de build. Compose
monte ce fichier dans les deux services ; l'API et PostgreSQL le lisent via leurs
variables `_FILE`. Ce fichier reste en clair sur la machine : ce mécanisme évite
le mot de passe dans l'image ou les variables d'environnement, sans le chiffrer.
Conserver le même secret tant que le volume existe : PostgreSQL l'utilise lors
de l'initialisation, pas pour changer automatiquement un mot de passe existant.

Pour démarrer l'API déjà publiée, après avoir créé le secret :

```powershell
$env:API_IMAGE = "ghcr.io/adriencambier1/tp-docker-m2-api:1.0.1"
docker compose up -d --no-build --wait --wait-timeout 120
docker compose run --rm --no-deps tests
docker compose down
Remove-Item Env:API_IMAGE
```

Compose utilise directement l'image PostgreSQL Chainguard épinglée par digest.
Le package DB public est une copie de cette même image.

## 2. Comparaison avant / après

La colonne « avant » reprend les mesures du durcissement initial. La colonne
« après » a été vérifiée sur le build local nettoyé le 8 octobre 2026.
Les tailles sont celles affichées par Docker ; les CVE dépendent de la date du scan.

| Critère | API avant | API après | DB avant | DB après |
|---|---|---|---|---|
| Base | `python:3.10-slim` | Chainguard Python, digest fixé | `postgres:14-alpine` | Chainguard PostgreSQL, digest fixé |
| Taille | 223 Mo | 122 Mo | 415 Mo | 540 Mo |
| Utilisateur | root | UID 65532 | root puis `gosu` | UID 70 dès le démarrage |
| Shell | présent | absent | présent | présent |
| CVE Trivy, toutes sévérités | 185, dont 47 HIGH | 0 | 47, dont 1 CRITICAL et 22 HIGH | 0 |
| Efficience Dive | 97,36 % | 99,71 % | — | — |
| Port publié | 5000, toutes interfaces | `127.0.0.1:5000` | 5432, toutes interfaces | aucun |
| Contenu de `/app` | code, Git, tests et configuration | `app.py` et dépendances runtime | — | — |

La base Chainguard PostgreSQL est plus lourde que l'ancienne image Alpine, mais
elle est imposée par le sujet. Son script d'entrée utilise un shell pour
initialiser la base et lire le secret ; la contrainte sans shell concerne l'API.

## 3. Images de base et reproductibilité

L'API utilise Chainguard Python, une des bases autorisées par le sujet. Le builder
`latest-dev` contient pip ; le runtime `latest` ne contient ni shell, ni compilateur,
ni gestionnaire de paquets. Les deux images utilisent Python 3.14 et Wolfi.
Le runtime s'exécute en utilisateur non privilégié.

Les deux `FROM` et l'image PostgreSQL sont fixés par digest SHA256. Les tags
`latest` et `latest-dev` servent de repères ; le digest détermine l'image utilisée.
La CI refuse un `FROM` sans digest. L'image de test, Hadolint, Dive et Trivy
utilisent également des images fixées par digest.

`requirements.txt` fixe les versions des dépendances directes et transitives.
Il est copié avant le code pour réutiliser la couche d'installation lorsque seul
`app.py` change. L'installation utilise `--no-cache-dir --no-compile` : pas de cache
pip ni de fichiers `.pyc` dans les dépendances copiées. Seuls le code et les
bibliothèques nécessaires passent dans l'image finale. `.dockerignore` autorise
uniquement `app.py` et `requirements.txt` dans le contexte utile du build.

## 4. Sondes et fonctionnement sans shell

La sonde de l'API est définie une seule fois dans le Dockerfile, puis héritée par
Compose. Elle appelle directement Python, en forme exec :

```dockerfile
HEALTHCHECK --interval=10s --timeout=5s --start-period=10s --retries=5 \
    CMD ["/usr/bin/python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:5000/health', timeout=3)"]
```

`urllib.request` est fourni par Python. Une erreur HTTP ou réseau fait échouer la
sonde, sans installer curl ou ajouter un shell.

La sonde PostgreSQL appelle directement `pg_isready`, fourni par l'image :

```yaml
test: ["CMD", "pg_isready", "-h", "127.0.0.1", "-U", "${POSTGRES_USER:-appuser}", "-d", "${POSTGRES_DB:-appdb}"]
```

`depends_on` avec `service_healthy` attend PostgreSQL avant de démarrer l'API.
`docker compose up --wait` attend ensuite les deux sondes avant les tests.
Le test `/dbtest` vérifie une vraie connexion avec authentification et `SELECT 1`.
Les tests fournis importent `app.py` et utilisent `app.test_client()`. Le service
`tests` partage les paramètres de connexion et le secret avec l'API ; il installe
les dépendances runtime et de test dans un tmpfs et lit le dépôt en lecture seule.
Ce tmpfs autorise le chargement des bibliothèques natives de psycopg2 (`exec`).
Son image Python de développement dispose de pip et d'un shell, contrairement
au runtime de production. La CI interroge aussi `/health` et `/dbtest` en HTTP
sur l'API démarrée, pour vérifier l'image qui sera publiée.

PostgreSQL rejoint uniquement le réseau interne `backend`. Les deux services
ont un système de fichiers en lecture seule, aucune capability Linux et
`no-new-privileges`. Les écritures temporaires utilisent des tmpfs ; les données
PostgreSQL utilisent un volume monté sur `/var/lib/postgresql`, appartenant à
l'UID 70. Gunicorn utilise `/dev/shm` pour ses fichiers temporaires.

## 5. Remédiations des dépendances et du code

Les vulnérabilités relevées lors du durcissement initial ont motivé ces changements :

| Dépendance | Avant | Version retenue | Remédiation |
|---|---|---|---|
| Werkzeug | 2.3.3 | 3.1.9 | CVE-2024-34069 HIGH et plusieurs CVE MEDIUM |
| Flask | 2.3.2 | 3.1.3 | CVE-2026-27205 LOW |
| pytest | 7.4.0 | 9.1.1 | CVE-2025-71176 MEDIUM ; déplacé hors du runtime |
| psycopg2-binary | non fixé | 2.9.13 | version fixée, compatible avec le runtime testé |
| Gunicorn | absent | 26.2.0 | serveur WSGI à la place du serveur de développement Flask |

Les outils du builder, notamment pip, setuptools et wheel, ne sont pas copiés
dans le runtime. Les dépendances transitives sont également fixées pour éviter
que leur version change entre deux installations du même fichier.

Le code respecte la configuration Flake8 fournie. Les espaces inutiles, lignes
vides et fins de fichier ont été corrigés. Le mot de passe par défaut a été
supprimé, la connexion a un délai maximal de cinq secondes et `/dbtest` renvoie
un message neutre en cas d'échec, avec les détails dans les logs.

`test_app.py` conserve la fixture Flask et les trois tests fournis dans le sujet ;
seuls les espaces entre les fonctions sont normalisés. `requirements.txt` contient
uniquement les dépendances de l'application. Le service de tests installe
`pytest==9.1.1` séparément ; la CI installe `flake8==7.4.1` dans son job de lint.
Ces outils ne sont pas installés dans l'image de production.

## 6. CI/CD et publication

Les six jobs correspondent aux étapes demandées :

```text
Flake8 + Hadolint → BuildKit / Dive → Trivy + intégration → publication GHCR
```

Flake8 et Hadolint bloquent le build. Dive impose au moins 80 % d'efficience.
Trivy scanne l'API, les dépendances du dépôt et PostgreSQL ; une vulnérabilité
HIGH ou CRITICAL disposant d'une correction fait échouer le job.
L'intégration démarre Compose, vérifie les routes en HTTP puis exécute les trois
tests pytest fournis dans le service temporaire. La publication attend la réussite
de ces contrôles.

Le workflow ferme les permissions par défaut. Les jobs de lecture ont
`contents: read` ; seul celui de publication a `packages: write`. Il utilise
`GITHUB_TOKEN`, sans jeton personnel. Toutes les actions sont fixées par SHA
complet et les checkouts n'enregistrent pas les identifiants Git.
Les pull requests exécutent les contrôles sans publier.

L'API est construite une seule fois, puis transférée entre les jobs par
`docker save` / `docker load`. La publication réutilise l'image testée et scannée.
Le digest PostgreSQL est lu dans Compose pour scanner et publier la même base.

Un push sur `main` publie `edge` et `sha-<commit>`. Un tag `vX.Y.Z` publie
`X.Y.Z`, `X.Y`, `X`, `latest` et `sha-<commit>` ; le tag majeur `0` est omis.
Pour une prochaine version, après avoir commité les changements :

```powershell
git push origin main
git tag v1.0.2
git push origin v1.0.2
```

## 7. Preuves d'exécution

Vérifications locales du projet nettoyé, le 8 octobre 2026 :

| Contrôle | Résultat |
|---|---|
| Flake8 | code de sortie 0 |
| Hadolint | code de sortie 0 |
| Configuration Compose | valide ; API et DB au démarrage, tests dans un profil facultatif |
| Actionlint et ShellCheck du workflow | code de sortie 0 |
| Build multi-stage | réussi |
| Contexte de build (`.dockerignore`) | uniquement `app.py` et `requirements.txt` ; ni `.git` ni `secrets/` |
| Runtime API | UID 65532 ; aucun shell, pip ou compilateur ; aucun `.pyc` dans les dépendances |
| Dive | 99,7126 % ; seuil de 80 % validé ; 237 208 octets gaspillés |
| Trivy API / dépendances / DB | 0 vulnérabilité, toutes sévérités |
| Compose sur un volume neuf | API et PostgreSQL `healthy` |
| Tests pytest fournis | 3 réussis en 0,23 s, sans avertissement de marqueur |
| Smoke test HTTP | `/health` et `/dbtest` répondent avec un statut 200 |

Les tests fournis ont été revérifiés avec un projet Compose distinct, un volume
neuf et le port HTTP 15001. Le conteneur de tests reste sur les réseaux Compose :
il contacte PostgreSQL via `db:5432`, sans publier le port de la base.

```powershell
docker compose run --rm --no-deps tests
# test_health PASSED, test_hello PASSED, test_dbtest PASSED
# 3 passed in 0.23s
```

La [CI de la version 1.0.1](https://github.com/AdrienCambier1/tp-docker-m2/actions?query=branch%3Av1.0.1)
prouve l'exécution complète du pipeline sur GitHub et la publication sur GHCR
(la [CI de la version 1.0.0](https://github.com/AdrienCambier1/tp-docker-m2/actions/runs/37759486337)
reste disponible pour la publication précédente).
