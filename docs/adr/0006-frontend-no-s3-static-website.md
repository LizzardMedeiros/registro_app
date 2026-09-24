# 0006. Frontend no S3 Static Website com configuração gerada

- Status: Aceito
- Data: 2026-09-24

## Contexto

O frontend é HTML/CSS/JS puro, sem build, e chamava `/api` na mesma origem
(proxy do nginx no docker compose). O `DEPLOY.md` pede S3 Static Website sem
CloudFront, porque contas novas podem exigir verificação do Support para criar
distribuições.

## Decisão

- Bucket `registro-<env>-<conta>-site` com Static Website Hosting (HTTP).
- Bloqueio de ACLs mantido (`BlockPublicAcls`/`IgnorePublicAcls` e
  `BucketOwnerEnforced`); policy pública apenas para `s3:GetObject` nos objetos.
  O deploy aborta se o bloqueio de acesso público da conta impedir a policy.
- `frontend/config.js` define `window.APP_CONFIG = { apiBaseUrl, version }`. Em
  desenvolvimento, `apiBaseUrl` vazio mantém a mesma origem; no deploy,
  `scripts/build-frontend.sh` gera o arquivo com `http://<ip-da-task>:3000` e o
  commit publicado, com escape via `jq`.
- A API libera CORS apenas para a origem do site (`CORS_ORIGIN`).
- Arquivos publicados com `Cache-Control: no-cache` (revalidação por ETag), para
  a versão nova aparecer sem invalidação. O rodapé mostra a versão.

## Consequências

- **Site e API em HTTP**: senhas e tokens trafegam sem criptografia. Aceitável só
  com dados sintéticos do laboratório; o responsável foi avisado. Não usar
  senhas reais.
- O token JWT fica no `localStorage`, exposto a XSS; aceito no laboratório.
- `config.js` é público: nunca contém segredos (há teste para isso).
