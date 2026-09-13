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
# Supabase's session pooler chains to a private root ("Supabase Root 2021 CA") that is not in any
# public trust store, so verified TLS to the database fails without it. NODE_EXTRA_CA_CERTS appends
# to the default store, so public CAs (JWKS over HTTPS) keep working. Never disable verification.
COPY --from=build --chown=node:node /app/apps/server/supabase-root-2021.crt ./apps/server/supabase-root-2021.crt
ENV NODE_EXTRA_CA_CERTS=/app/apps/server/supabase-root-2021.crt
USER node
EXPOSE 3000
CMD ["node", "apps/server/dist/main.js"]
