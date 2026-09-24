# 0011. Ferramentas de teste e qualidade

- Status: Aceito
- Data: 2026-09-24

## Contexto

O repositório não tinha testes, linters nem CI. A stack é JavaScript (CommonJS)
sem TypeScript, e o frontend não tem bundler.

## Decisão

- API: `node:test` nativo, sem dependência extra. `createApp()` separado do
  `listen` para testar numa porta efêmera. Testes de integração com PostgreSQL
  real e descartável cobrem migrations idempotentes, cadastro, login, `/me`,
  e-mail duplicado e persistência.
- Frontend: `node:test` com `jsdom`, carregando `index.html` e `app.js` reais com
  `fetch` simulado (URL da API vinda da config, erros, sessão, logout).
- Lint e formatação: ESLint 9 (flat config, `@eslint/js` recommended) e
  Prettier, na raiz do repositório com lockfile próprio.
- Shell: `bash -n`, `shellcheck -x` e `scripts/test/run.sh` (políticas geradas,
  validação de argumentos, mascaramento de segredos, garantias estruturais).
- Workflows: `actionlint`.
- Sem verificação de tipos: o projeto não usa TypeScript nem JSDoc tipado, e
  adicionar `tsc --checkJs` exigiria anotar o código todo. Testes de
  comportamento e o ESLint cobrem essa necessidade no escopo do laboratório.

## Consequências

- Os testes encontraram um bug real: o cadastro validava o e-mail antes do
  `trim`, e rejeitava `"ana@x.com "`. Corrigido normalizando a entrada antes de
  validar.
- Node 22 fixado em `.nvmrc`, `engines` e CI; a imagem passou de `node:20` para
  `node:22-alpine`.
