# Registro App

Aplicação simples de login e registro.

- **API**: Node.js + Express, senhas com bcrypt, autenticação via JWT
- **Banco**: PostgreSQL 16
- **Front**: HTML/CSS/JS puro servido por nginx (faz proxy de `/api` para a API)

## Rodando

```bash
docker compose up --build
```

- Front: http://localhost:8080
- API: http://localhost:3000

Para customizar credenciais/segredo, copie `.env.example` para `.env` e ajuste.

## Desenvolvimento

Requer Node 22 (`nvm use`), Docker, `jq` e `shellcheck`.

```bash
npm ci && npm ci --prefix api
npx eslint . && npx prettier --check .        # lint e formatação
npm run test:frontend                          # frontend (jsdom)
npm run test:shell                             # scripts e políticas IAM
# API, incluindo integração com um Postgres descartável:
docker run -d --rm --name pg-test -e POSTGRES_USER=app -e POSTGRES_PASSWORD=app \
  -e POSTGRES_DB=registro_test -p 55432:5432 postgres:16-alpine
DATABASE_URL=postgres://app:app@127.0.0.1:55432/registro_test npm test --prefix api
```

## Deploy na AWS

O pipeline `.github/workflows/ci-cd.yml` valida cada PR e publica cada push na
`main` no ambiente do laboratório (ECS Fargate + RDS + S3 website), via OIDC.

- Como operar, ver logs, recuperar falhas e encerrar: [`docs/operations.md`](docs/operations.md)
- Decisões de arquitetura (ADRs): [`docs/adr/`](docs/adr/README.md)
- Contexto, entrevista e custo: [`docs/deploy-decisions.md`](docs/deploy-decisions.md)
- Roteiro do workshop para o agente: [`DEPLOY.md`](DEPLOY.md)

## Endpoints

| Método | Rota            | Corpo                         | Descrição                        |
|--------|-----------------|-------------------------------|----------------------------------|
| POST   | `/api/register` | `{ name, email, password }`   | Cria usuário e retorna token     |
| POST   | `/api/login`    | `{ email, password }`         | Autentica e retorna token        |
| GET    | `/api/me`       | — (header `Authorization: Bearer <token>`) | Dados do usuário logado |
| GET    | `/api/health`   | —                             | Health check                     |
