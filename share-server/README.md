# FinderFlow Share Server

Single-process Node.js relay/control plane, PostgreSQL metadata, a recipient frontend and a Caddy TLS deployment.

Full setup and limits: [secure-sharing.md](../docs/secure-sharing.md).

```sh
npm ci
npm test
```

Production: fill `.env` from `.env.example`, point the hostname to the server, and run `docker compose up -d --build`. This repository does not deploy or configure a public domain automatically.

For a manually managed deployment, set `DATABASE_URL`, `PUBLIC_ORIGIN` (canonical HTTPS origin), `ENROLLMENT_CODE` (24+ characters; use 32 random bytes), and optionally `PORT`/`BIND_ADDRESS`. Run `npm start` behind a TLS reverse proxy that preserves Host, forwards WebSocket upgrades, disables response buffering and does not cache or log private traffic. Only `DEV_ALLOW_HTTP=1` permits HTTP and then only a loopback public origin.
