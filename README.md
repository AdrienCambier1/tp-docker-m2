# Hardening Flask / PostgreSQL

API Flask et base PostgreSQL durcies, avec contrôle qualité, scans de sécurité
et publication sur GHCR.

## 1. Packages publics et exécution

- [API](https://github.com/AdrienCambier1/tp-docker-m2/pkgs/container/tp-docker-m2-api)
- [PostgreSQL](https://github.com/AdrienCambier1/tp-docker-m2/pkgs/container/tp-docker-m2-db)

```powershell
docker pull ghcr.io/adriencambier1/tp-docker-m2-api:1.0.0
docker pull ghcr.io/adriencambier1/tp-docker-m2-db:1.0.0
```

La version `1.0.0` est la première livraison durcie. Le code actuel est également
publié sous `edge` et `sha-5d44fbb`. Le package DB reprend le digest Chainguard
utilisé dans Compose.

Avec Docker Desktop en mode Linux, depuis la racine du dépôt dans PowerShell :

```powershell
New-Item -ItemType Directory -Force secrets | Out-Null
if (!(Test-Path secrets/db_password.txt)) {
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($bytes)
    $rng.Dispose()
    [IO.File]::WriteAllText("$PWD/secrets/db_password.txt", [Convert]::ToBase64String($bytes))
}
docker compose up -d --build --wait --wait-timeout 120
docker compose run --rm --no-deps tests
```

L'API répond sur `http://127.0.0.1:5000`. Pour tester la version publiée,
remplacer la commande `up` par :

```powershell
$env:API_IMAGE = "ghcr.io/adriencambier1/tp-docker-m2-api:1.0.0"
docker compose up -d --no-build --wait --wait-timeout 120
```

Arrêt : `docker compose down`. Après un test de l'image publiée,
`Remove-Item Env:API_IMAGE` rétablit le choix de l'image locale.
Le secret est un fichier local ignoré par Git, monté via les variables `_FILE`.
Il doit être conservé avec le volume PostgreSQL : sa modification seule ne change
pas le mot de passe d'une base déjà initialisée.

## 2. Comparaison avant / après

Mesures initiales du durcissement et mesures du build actuel, au 8 octobre 2026.

| Critère | API avant | API après | DB avant | DB après |
|---|---|---|---|---|
| Taille Docker | 223 Mo | 122 Mo | 415 Mo | 540 Mo |
| Utilisateur | root | UID 65532 | root puis `gosu` | UID 70 |
| Shell | oui | non | oui | oui |
| CVE Trivy, toutes sévérités | 185 | 0 | 47 | 0 |
| Efficience Dive | 97,36 % | 99,71 % | — | — |
| Port publié | 5000, toutes interfaces | 5000, localhost | 5432 | aucun |

Le shell PostgreSQL est utilisé par le script d'initialisation de l'image officielle
Chainguard. L'absence de shell est imposée au runtime de l'API.

## 3. Images de base et reproductibilité

L'API utilise Chainguard Python : un builder `latest-dev` avec pip et un runtime
minimal sans shell, compilateur ou gestionnaire de paquets. PostgreSQL utilise
Chainguard, comme demandé. Les bases et outils de CI sont fixés par digest SHA256 ;
les tags `latest` des bases ne déterminent donc pas leur contenu.

Les dépendances directes et transitives sont fixées dans `requirements.txt`.
Le manifeste est copié avant le code pour conserver la couche d'installation en
cache. `--no-cache-dir --no-compile` évite les caches pip et les `.pyc`.
Seuls le code et les dépendances runtime sont copiés dans l'image finale.
`.dockerignore` exclut tout le contexte sauf `app.py` et `requirements.txt`.

## 4. Healthchecks et isolation

La sonde API, définie dans le Dockerfile et héritée par Compose, exécute directement
Python et `urllib.request` sur `/health`. Une erreur HTTP ou réseau fait échouer
la sonde. PostgreSQL utilise `pg_isready` en liste exec. Aucune sonde ne dépend
d'un shell ou de curl.

`depends_on: service_healthy` attend la base avant de démarrer l'API ; `up --wait`
attend les deux sondes avant les tests. La base est sur un réseau interne sans port
publié. Les services tournent sans root, en lecture seule, sans capabilities et
avec `no-new-privileges`. Les écritures passent par des tmpfs et le volume de données.

Le profil `test` lance temporairement pytest avec le client Flask fourni et la
même connexion PostgreSQL. Son image de développement reste distincte du runtime
API. La CI vérifie aussi `/health` et `/dbtest` en HTTP sur l'API démarrée.

## 5. Remédiations des dépendances et du code

Scan du manifeste original :

| Paquet initial | Vulnérabilités | Correction |
|---|---|---|
| Flask 2.3.2 | CVE-2026-27205 (LOW) | 3.1.3 |
| Werkzeug 2.3.3 | CVE-2024-34069 (HIGH) | 3.1.9 |
| Werkzeug 2.3.3 | CVE-2023-46136, CVE-2024-49766, CVE-2024-49767, CVE-2025-66221, CVE-2026-21860, CVE-2026-27199, CVE-2026-102598 (MEDIUM) | 3.1.9 |
| pytest 7.4.0 | CVE-2025-71176 (MEDIUM) | 9.1.1, installé uniquement pour les tests |

`psycopg2-binary` est fixé à 2.9.13 et Gunicorn 26.2.0 remplace le serveur Flask
de développement. Pip et les outils du builder ne sont pas copiés dans le runtime.

La configuration Flake8 fournie est conservée. Les huit écarts E302, l'espace sur
ligne vide W293, la fin de fichier W292 et la ligne finale W391 ont été corrigés,
bien qu'ignorés par cette configuration. Le mot de passe par défaut a été retiré ;
les erreurs PostgreSQL restent dans les logs et la connexion est limitée à cinq
secondes. Les tests fournis conservent leur logique ; `pytest.ini` déclare leur
marqueur `integration`.

## 6. CI/CD et publication

```text
Flake8 + Hadolint → BuildKit / Dive → Trivy + intégration → publication GHCR
```

Les six jobs bloquent la publication en cas d'échec. Dive impose 80 % d'efficience ;
Trivy échoue sur les HIGH/CRITICAL corrigeables dans l'API, les dépendances et la DB.
L'intégration attend les sondes, vérifie les routes HTTP, lance pytest et nettoie
les ressources avec `if: always()`.

Les permissions globales sont fermées ; seul `release` reçoit `packages: write`.
GHCR utilise `GITHUB_TOKEN`. Toutes les actions sont fixées par SHA complet.
L'image API est transférée entre jobs, puis publiée sans reconstruction.

Les pull requests ne publient rien. Un push sur `main` publie `edge` et
`sha-<commit>`. Un tag `vX.Y.Z` publie `X.Y.Z`, `X.Y`, `X`, `latest` et
`sha-<commit>` ; le tag majeur `0` est omis.

## 7. Preuves d'exécution

[CI du commit 5d44fbb](https://github.com/AdrienCambier1/tp-docker-m2/actions/runs/37774192688) :
les six jobs ont réussi, publication incluse. Les deux packages sont accessibles
publiquement avec les tags indiqués en section 1.

Extraits des vérifications locales du 8 octobre 2026 :

```text
Flake8 et Hadolint : aucune violation, code de sortie 0
Dive : efficiency 99.7126 %, wastedBytes 237208, PASS
Trivy API / dépendances / DB : 0 vulnérabilité, toutes sévérités
Compose : api healthy, db healthy
/health : {"status":"ok"}
/dbtest : {"db_connection":"successful"}
pytest : 3 passed in 0.23s
```
