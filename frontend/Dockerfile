# Build stage
FROM node:20-alpine AS build

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY . .
RUN npm run build

# Production serve stage
FROM nginx:alpine

COPY --from=build /app/dist /usr/share/nginx/html
COPY templates/default.conf.template /etc/nginx/templates/default.conf.template

# Defaults for docker-compose; override on Cloud Run (PORT is injected there).
ENV BACKEND_URL=http://backend:8000 \
    PORT=80

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
