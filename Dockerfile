# syntax=docker/dockerfile:1.28.0@sha256:bb22d9815c728170f72750f4e5b0d672e06176142e1d602c7e66c050100b7e5b

FROM cgr.dev/chainguard/python:latest-dev@sha256:dde1a2549dd62864f0263dae8e877680837b4e738a7ecc85c671c55c069848ac AS builder

ENV PIP_CACHE_DIR=/home/nonroot/.cache/pip \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /build

COPY requirements.txt .
RUN --mount=type=cache,id=pip-cache,target=/home/nonroot/.cache/pip,uid=65532,gid=65532,sharing=locked \
    --mount=type=secret,id=pip_token,required=true,uid=65532,gid=65532,mode=0400 \
    test -s /run/secrets/pip_token \
    && pip install --no-compile --target=/build/install -r requirements.txt \
    && rm -rf /build/install/bin
COPY app.py .

FROM cgr.dev/chainguard/python:latest@sha256:49fd266eb8a1331194c318b742087c7a2939cc5794fa64f17feb9e17e12703e2 AS runtime

USER 0:0
RUN ["/usr/bin/python", "-c", "import pathlib, shutil, sysconfig; shutil.rmtree(pathlib.Path(sysconfig.get_path('stdlib')) / 'ensurepip'); shutil.rmtree('/usr/share/python-wheels')"]

ENV PYTHONPATH=/app/site-packages \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app
COPY --from=builder /build/install /app/site-packages
COPY --from=builder /build/app.py /app/app.py
USER 65532:65532
EXPOSE 5000

HEALTHCHECK --interval=10s --timeout=5s --start-period=10s --retries=5 \
    CMD ["/usr/bin/python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:5000/health', timeout=3)"]

ENTRYPOINT ["/usr/bin/python", "-m", "gunicorn"]
CMD ["--bind", "0.0.0.0:5000", "--workers", "2", "--worker-tmp-dir", "/dev/shm", "--access-logfile", "-", "app:app"]
