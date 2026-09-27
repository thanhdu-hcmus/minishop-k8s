FROM node:22.16.0-alpine3.21@sha256:9f3ae04faa4d2188825803bf890792f33cc39033c9241fc6bb201149470436ca AS dependencies

WORKDIR /usr/src/app

COPY package.json package-lock.json ./

RUN npm ci

FROM dependencies AS test

COPY app ./app
COPY db/items.json ./db/items.json
COPY index.js ./
COPY test ./test

RUN npm test

FROM node:22.16.0-alpine3.21@sha256:9f3ae04faa4d2188825803bf890792f33cc39033c9241fc6bb201149470436ca AS runtime

ARG SOURCE_REVISION

WORKDIR /usr/src/app

ENV NODE_ENV=production

LABEL org.opencontainers.image.licenses="Apache-2.0"
LABEL org.opencontainers.image.source="https://github.com/thanhdu-hcmus/minishop-k8s"
LABEL org.opencontainers.image.revision="$SOURCE_REVISION"

COPY --from=dependencies /usr/src/app/node_modules ./node_modules
COPY LICENSE ./LICENSE
COPY package.json ./
COPY app ./app
COPY db/items.json ./db/items.json
COPY index.js ./

EXPOSE 3001

USER node

CMD ["npm", "start"]
