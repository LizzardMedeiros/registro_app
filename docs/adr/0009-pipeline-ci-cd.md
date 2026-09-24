# 0009. Pipeline de CI/CD com gates e artefato único

- Status: Aceito
- Data: 2026-09-24

## Contexto

O `DEPLOY.md` exige CI em PRs e pushes na `main`, publicação automática a cada
push válido na `main`, bloqueio quando algo falha e deploy do mesmo artefato
validado.

## Decisão

Workflow único `.github/workflows/ci-cd.yml`:

1. Jobs de validação em paralelo: `lint` (ESLint e Prettier), `test-api` (testes
   com PostgreSQL 16 como service, `REQUIRE_DB=1` para não pular a integração),
   `test-frontend` (jsdom e build), `shell` (bash -n, shellcheck, testes de
   políticas, actionlint) e `image` (build, CA legível pelo usuário não-root com
   `DB_SSL=true`, health check do container, recusa do segredo padrão).
2. O job `image` exporta a imagem validada como artefato; o `deploy` carrega
   essa mesma imagem e a publica no ECR com a tag do commit (12 caracteres). A
   task definition referencia o **digest**.
3. `deploy` depende de todos os jobs (`needs`) e roda só na `main`, em push ou
   `workflow_dispatch`. Mudanças apenas em `*.md` e `docs/` dispensam o deploy,
   sem pular as validações.
4. `concurrency: deploy-lab` sem cancelamento: um deploy por vez no ambiente.
5. O resumo do workflow registra commit, URLs, task definition e o resultado da
   verificação funcional (health, site, CORS, cadastro e consulta no banco).

## Consequências

- Um teste quebrado impede a publicação e a versão anterior continua no ar.
- Repositório ECR com tags imutáveis: re-executar o mesmo commit reaproveita a
  imagem já enviada.
- O smoke test cria usuários sintéticos `smoke+<timestamp>@example.com` no banco.
