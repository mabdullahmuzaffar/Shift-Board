# syntax=docker/dockerfile:1.7
# ---------------------------------------------------------------- builder ----
# Wheels are built in a throwaway stage so the runtime image carries no
# compilers. pyodbc needs unixodbc-dev to build but only unixodbc to run.
FROM python:3.12-slim-bookworm AS builder

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        curl \
        gnupg \
        unixodbc-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /wheels
COPY requirements.txt .
RUN pip wheel --wheel-dir /wheels -r requirements.txt

# ---------------------------------------------------------------- runtime ----
FROM python:3.12-slim-bookworm AS runtime

# Injected by the pipeline from the Git SHA and build id. Kept as the LAST
# layer-invalidating step so changing them does not rebuild dependencies.
ARG GIT_SHA=unknown
ARG BUILD_ID=local
ARG IMAGE_VERSION=1.0.0

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PYTHONPATH=/app

# Microsoft ODBC Driver 18 for Azure SQL, plus tini for correct PID-1 signal
# forwarding so SIGTERM reaches uvicorn and connections drain cleanly.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg tini unixodbc \
    && curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
        | gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg \
    && echo "deb [arch=amd64,arm64 signed-by=/usr/share/keyrings/microsoft-prod.gpg] https://packages.microsoft.com/debian/12/prod bookworm main" \
        > /etc/apt/sources.list.d/mssql-release.list \
    && apt-get update \
    && ACCEPT_EULA=Y apt-get install -y --no-install-recommends msodbcsql18 \
    && apt-get purge -y gnupg curl \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd --gid 10001 app \
    && useradd --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app

WORKDIR /app

COPY --from=builder /wheels /wheels
COPY requirements.txt .
RUN pip install --no-index --find-links=/wheels -r requirements.txt \
    && rm -rf /wheels

COPY --chown=app:app app ./app
COPY --chown=app:app migrations ./migrations
COPY --chown=app:app alembic.ini .

USER 10001:10001

ENV SHIFTBOARD_SERVICE_NAME=shift-api
LABEL org.opencontainers.image.title="shiftboard-shift-api" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.source="https://github.com/YOUR_ORG/shiftboard" \
      org.opencontainers.image.licenses="MIT" \
      io.shiftboard.build-id="${BUILD_ID}"

EXPOSE 8000

# Kubernetes probes are the real health gate; this HEALTHCHECK helps
# docker-compose and local runs only.
HEALTHCHECK --interval=30s --timeout=3s --start-period=20s --retries=3 \
    CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/healthz',timeout=2).status==200 else 1)"

ENTRYPOINT ["/usr/bin/tini", "--"]
# One worker per pod: scale with replicas, not with in-pod processes, so the
# HPA sees real per-pod utilisation and rollouts are granular.
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", \
     "--workers", "1", "--no-server-header", "--timeout-graceful-shutdown", "25"]
