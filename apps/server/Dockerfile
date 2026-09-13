FROM node:22.20.0-bookworm-slim AS build
WORKDIR /app
COPY package.json package-lock.json tsconfig.base.json ./
COPY apps/server/package.json apps/server/package.json
COPY packages/protocol/package.json packages/protocol/package.json
COPY packages/game-engine/package.json packages/game-engine/package.json
RUN npm ci
COPY apps/server apps/server
COPY packages packages
RUN npm run build && npm prune --omit=dev

FROM node:22.20.0-bookworm-slim AS runtime
ENV NODE_ENV=production
WORKDIR /app
COPY --from=build --chown=node:node /app/node_modules ./node_modules
COPY --from=build --chown=node:node /app/apps/server/package.json ./apps/server/package.json
COPY --from=build --chown=node:node /app/apps/server/dist ./apps/server/dist
COPY --from=build --chown=node:node /app/packages ./packages
# Supabase's session pooler chains to a private root that is not in any public trust store, so
# verified TLS to the database fails without it. Both published roots are bundled: the pooler serves
# the 2021 root today, and the 2025 root is a key rollover under the same subject name, so trusting
# both survives the migration. NODE_EXTRA_CA_CERTS appends to the default store, leaving public CAs
# (JWKS over HTTPS) working. Never disable verification.
COPY --from=build --chown=node:node /app/apps/server/supabase-roots.crt ./apps/server/supabase-roots.crt
ENV NODE_EXTRA_CA_CERTS=/app/apps/server/supabase-roots.crt
USER node
EXPOSE 3000
CMD ["node", "apps/server/dist/main.js"]
