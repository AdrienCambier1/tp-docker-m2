FROM cgr.dev/chainguard/python:latest-dev@sha256:894aed3297d91283e1fc4c542f5374a4b5f3726134fda7c94eaa539342be1e05 AS builder

WORKDIR /build

COPY requirements.txt .
RUN pip install --no-cache-dir --no-compile --target=/build/install -r requirements.txt \
    && rm -rf /build/install/bin
COPY app.py .

FROM cgr.dev/chainguard/python:latest@sha256:b6248c85ba9b97e1e61b30197f309cc4d21661f889fefa5268f0a7bc530dad46 AS runtime

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
