FROM node:22-slim AS frontend-build

WORKDIR /app/frontend

COPY frontend/package*.json ./

RUN npm ci --registry=https://registry.npmmirror.com

COPY frontend/ ./

ENV VITE_BACKEND_SERVER=/
ENV VITE_FILE_BASE_URL=/

RUN npm run build

FROM node:22-slim AS production

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        nginx \
        fonts-liberation \
        libfontconfig1 \
        libfreetype6 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app/backend

COPY backend/package*.json ./

RUN npm ci --omit=dev --registry=https://registry.npmmirror.com

COPY backend/ ./

COPY --from=frontend-build /app/frontend/dist /usr/share/nginx/html

COPY nginx.conf /etc/nginx/nginx.conf

COPY docker-entrypoint.sh /
RUN chmod +x /docker-entrypoint.sh

ENV NODE_ENV=production
ENV PORT=8888

EXPOSE 80

ENTRYPOINT ["/docker-entrypoint.sh"]
