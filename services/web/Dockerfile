# syntax=docker/dockerfile:1.7
FROM node:22-alpine AS builder

WORKDIR /src

# Lockfile first: dependency layer is cached until the lockfile changes.
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund

COPY tsconfig.json vite.config.ts index.html ./
COPY src ./src

ARG VITE_DEMO_WORKER_ID=""
ENV VITE_DEMO_WORKER_ID=${VITE_DEMO_WORKER_ID}

RUN npx tsc -b && npx vite build

# ---------------------------------------------------------------- runtime ----
FROM nginxinc/nginx-unprivileged:1.27-alpine AS runtime

ARG GIT_SHA=unknown
ARG BUILD_ID=local
ARG IMAGE_VERSION=1.0.0

# nginx-unprivileged already runs as uid 101 and listens on 8080, so no
# CAP_NET_BIND_SERVICE is needed and the pod can drop all capabilities.
COPY --from=builder /src/dist /usr/share/nginx/html
# Placed under templates/ so the official entrypoint runs envsubst on it at
# start-up, injecting SHIFT_API_HOST from the Helm-managed env. The entrypoint
# only substitutes names that actually exist in the environment, so nginx's
# own $uri / $remote_addr variables pass through untouched.
COPY default.conf.template /etc/nginx/templates/default.conf.template

LABEL org.opencontainers.image.title="shiftboard-web" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.source="https://github.com/YOUR_ORG/shiftboard" \
      org.opencontainers.image.licenses="MIT" \
      io.shiftboard.build-id="${BUILD_ID}"

USER 101
EXPOSE 8080

STOPSIGNAL SIGQUIT
CMD ["nginx", "-g", "daemon off;"]
