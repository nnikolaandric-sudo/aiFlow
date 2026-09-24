FROM node:22-bookworm-slim
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev --no-audit --no-fund
COPY src ./src
COPY public ./public
USER node
ENV BIND_ADDRESS=0.0.0.0 PORT=8787 NODE_ENV=production
EXPOSE 8787
CMD ["node", "src/main.js"]
