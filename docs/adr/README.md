# Architecture Decision Records

Decisões de arquitetura do deploy do laboratório, no formato de Michael Nygard
(contexto, decisão, consequências). Um ADR aceito não é editado para mudar de
ideia: crie um novo que o substitua e marque o antigo como "Substituído por".

| ADR | Título | Status |
|---|---|---|
| [0001](0001-registrar-decisoes-em-adrs.md) | Registrar decisões em ADRs | Aceito |
| [0002](0002-conta-credenciais-e-regiao.md) | Conta, credenciais e região do laboratório | Aceito |
| [0003](0003-provisionamento-com-bash-e-aws-cli.md) | Provisionamento com Bash e AWS CLI, sem IaC | Aceito |
| [0004](0004-api-no-ecs-fargate-com-ip-publico.md) | API no ECS Fargate com IPv4 público, sem ALB | Aceito |
| [0005](0005-banco-rds-postgresql-single-az.md) | Banco RDS PostgreSQL Single-AZ privado e descartável | Aceito |
| [0006](0006-frontend-no-s3-static-website.md) | Frontend no S3 Static Website com configuração gerada | Aceito |
| [0007](0007-github-actions-com-oidc.md) | Autenticação do GitHub Actions na AWS por OIDC | Aceito |
| [0008](0008-segredos-no-ssm-parameter-store.md) | Segredos no SSM Parameter Store | Aceito |
| [0009](0009-pipeline-ci-cd.md) | Pipeline de CI/CD com gates e artefato único | Aceito |
| [0010](0010-ciclo-de-vida-do-ambiente.md) | Ciclo de vida: provisionamento explícito e destruição confirmada | Aceito |
| [0011](0011-ferramentas-de-qualidade.md) | Ferramentas de teste e qualidade | Aceito |

Contexto consolidado, respostas da entrevista e hipóteses pendentes:
[`docs/deploy-decisions.md`](../deploy-decisions.md).
