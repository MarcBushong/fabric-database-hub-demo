# The Ask relay's image, built by .github/workflows/ask-relay-image.yml and pulled by deploy.ps1 by its digest
# (config/versions.json askRelay.image). Both stages are Microsoft's Azure Linux Node.js images from MCR, pinned by
# digest: the build stage has npm; the runtime stage is distroless (no shell, no package manager) and runs as the
# image's non-root user. npm ci runs no install scripts. The Copilot runtime comes from the SDK's linux-x64 package
# in the lock file, and the relay starts it as a child process. Nothing secret is in the image: the relay has no
# Azure, Fabric, or GitHub credential of its own, only the GitHub OAuth App's public client ID, from its settings.
ARG BUILD_IMAGE=mcr.microsoft.com/azurelinux/base/nodejs:24.22.3-1-azl3.0.20261116@sha256:1c87a74ac10b0ad7711bcc862fa6a2b13e6a4db96d3a026dbb7fcf8486d57ba3
ARG RUNTIME_IMAGE=mcr.microsoft.com/azurelinux/distroless/nodejs:24.22.3-1-nonroot-azl3.0.20261116@sha256:64653c45a2fe9899f744e00716b140a3ea7d2202deb3a9d6307ddf62732e3e3c

FROM ${BUILD_IMAGE} AS build
WORKDIR /src
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund --ignore-scripts
COPY tsconfig.json ./
COPY src ./src
RUN npx tsc -p tsconfig.json && npm prune --omit=dev --ignore-scripts --no-audit --no-fund

FROM ${RUNTIME_IMAGE}
ARG RELAY_VERSION=0.1.0
ENV NODE_ENV=production \
    HOME=/tmp \
    COPILOT_HOME=/tmp/copilot \
    PORT=8080 \
    RELAY_VERSION=${RELAY_VERSION}
WORKDIR /app
COPY --from=build /src/package.json ./package.json
COPY --from=build /src/node_modules ./node_modules
COPY --from=build /src/dist ./dist
# The image's own non-root user; the relay writes only under /tmp (the Copilot runtime's state, gone with the replica).
USER nonroot
EXPOSE 8080
ENTRYPOINT ["/usr/bin/node", "dist/server.js"]
