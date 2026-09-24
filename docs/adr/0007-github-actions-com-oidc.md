# 0007. Autenticação do GitHub Actions na AWS por OIDC

- Status: Aceito
- Data: 2026-09-24

## Contexto

O pipeline precisa publicar na AWS sem credenciais permanentes. O `aws login`
local não serve para o runner. O fork usa **subject imutável** no token OIDC:
`repo:LizzardMedeiros@20029072/registro_app@1386286903:...`. Uma trust
`repo:LizzardMedeiros/*`, criada antes, nunca bateria com esse formato.

## Decisão

- Provedor OIDC `token.actions.githubusercontent.com` (audience
  `sts.amazonaws.com`), reutilizado se já existir.
- Role `github-actions-workshop` com trust `StringEquals` no subject exato
  `repo:LizzardMedeiros@20029072/registro_app@1386286903:environment:lab`, lido
  de `gh api repos/<repo>/actions/oidc/customization/sub`.
- Environment `lab` no GitHub, com deployment branch policy só para `main`, e as
  variáveis `AWS_ROLE_ARN`, `AWS_REGION`, `AWS_ACCOUNT_ID` e `LAB_ENV`.
- Somente o job `deploy` usa o environment e recebe `id-token: write`.
- Permissões da role: `AdministratorAccess`, escolha do responsável para não
  travar a pipeline numa conta pessoal e descartável.
- Tudo reproduzível por `scripts/bootstrap-github-oidc.sh`. O provedor e a role
  são tratados como compartilhados e não são removidos pelo `destroy.sh`.

## Consequências

- Pull requests e outras branches não conseguem assumir a role.
- Admin é amplo demais para produção: numa conta real, trocar por uma política
  limitada a VPC/EC2, RDS, ECS, ECR, IAM (`iam:PassRole` da role de execução),
  S3, SSM, CloudWatch Logs e STS, com restrição por prefixo e tags.
- Após o workshop, remover a role e o provedor manualmente se não forem reutilizados.
