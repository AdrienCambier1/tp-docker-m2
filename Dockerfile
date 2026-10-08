# syntax=docker/dockerfile:1

# =============================================================================
# Étage 1 - builder : résolution et installation des dépendances Python
# Variante -dev de Chainguard Python (pip + shell) : même distribution (Wolfi)
# et même version de Python (3.14) que le runtime, donc wheels compatibles ABI.
# Chainguard ne publie gratuitement que le tag "latest" : il est neutralisé
# par l'épinglage sur un digest SHA256 immuable.
# =============================================================================
FROM cgr.dev/chainguard/python:latest-dev@sha256:894aed3297d91283e1fc4c542f5374a4b5f3726134fda7c94eaa539342be1e05 AS builder

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /build

# Le manifeste est copié seul : la couche de dépendances reste en cache tant
# que requirements.txt ne change pas (modifier app.py ne réinstalle rien).
COPY requirements.txt .

# Installation dans un répertoire isolé (/build/install) qui sera le seul
# copié dans le runtime ; les scripts console (bin/) inutiles sont supprimés.
RUN pip install --no-cache-dir --target=/build/install -r requirements.txt \
    && rm -rf /build/install/bin

COPY app.py .

# =============================================================================
# Étage 2 - runtime : Chainguard Python distroless (sans shell, sans apk,
# sans pip, sans coreutils), utilisateur par défaut nonroot (UID/GID 65532)
# =============================================================================
FROM cgr.dev/chainguard/python:latest@sha256:b6248c85ba9b97e1e61b30197f309cc4d21661f889fefa5268f0a7bc530dad46 AS runtime

ENV PYTHONPATH=/app/site-packages \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

# Copies multi-étages avec chemins d'origine explicites. Les fichiers restent
# propriété de root (lecture seule pour l'utilisateur d'exécution).
COPY --from=builder /build/install /app/site-packages
COPY --from=builder /build/app.py /app/app.py

# Compte système dédié non privilégié "nonroot" fourni par l'image Chainguard
USER 65532:65532

EXPOSE 5000

# Sonde native : pas de shell ni de curl, on utilise l'interpréteur Python
# et sa bibliothèque standard (urllib) en forme exec.
HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=3 \
    CMD ["/usr/bin/python", "-c", "import sys, urllib.request; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:5000/health', timeout=3).status == 200 else 1)"]

# Serveur WSGI de production (le serveur de dev Flask n'est pas fait pour la prod)
ENTRYPOINT ["/usr/bin/python", "-m", "gunicorn"]
CMD ["--bind", "0.0.0.0:5000", "--workers", "2", "--worker-tmp-dir", "/dev/shm", "--access-logfile", "-", "app:app"]
