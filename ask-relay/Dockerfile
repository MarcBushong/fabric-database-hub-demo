# The Ask relay's image. Both stages use Microsoft's Azure Linux Node.js image from MCR, pinned by digest
# (config/versions.json askRelay.baseImage). The Copilot runtime comes from the SDK's linux-x64 package in the
# lock file; npm ci runs no install scripts, and the relay uses the runtime as a child process.
ARG NODE_IMAGE=mcr.microsoft.com/azurelinux/base/nodejs:24.22.3-1-azl3.0.20261116@sha256:1c87a74ac10b0ad7711bcc862fa6a2b13e6a4db96d3a026dbb7fcf8486d57ba3

FROM ${NODE_IMAGE} AS build
WORKDIR /src
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund --ignore-scripts
COPY tsconfig.json ./
COPY src ./src
RUN npx tsc -p tsconfig.json && npm prune --omit=dev --ignore-scripts --no-audit --no-fund

FROM ${NODE_IMAGE}
ENV NODE_ENV=production \
    HOME=/tmp \
    COPILOT_HOME=/tmp/copilot \
    PORT=8080
WORKDIR /app
COPY --from=build /src/package.json ./package.json
COPY --from=build /src/node_modules ./node_modules
COPY --from=build /src/dist ./dist
# Any non-root user: the relay writes only under /tmp (the Copilot runtime's state, removed with the replica).
USER 10001:10001
EXPOSE 8080
CMD ["node", "dist/server.js"]
