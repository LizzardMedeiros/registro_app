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

## Endpoints

| Método | Rota            | Corpo                         | Descrição                        |
|--------|-----------------|-------------------------------|----------------------------------|
| POST   | `/api/register` | `{ name, email, password }`   | Cria usuário e retorna token     |
| POST   | `/api/login`    | `{ email, password }`         | Autentica e retorna token        |
| GET    | `/api/me`       | — (header `Authorization: Bearer <token>`) | Dados do usuário logado |
| GET    | `/api/health`   | —                             | Health check                     |
