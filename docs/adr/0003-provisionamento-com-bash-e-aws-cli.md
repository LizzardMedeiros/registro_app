# 0003. Provisionamento com Bash e AWS CLI, sem IaC

- Status: Aceito
- Data: 2026-09-24

## Contexto

O `DEPLOY.md` proíbe Terraform, CloudFormation, CDK, Pulumi, SAM e similares. A
infraestrutura deve ser criada e removida por scripts Bash versionados, e o
mesmo código deve servir ao uso local e ao pipeline.

## Decisão

- `scripts/deploy.sh` cria ou atualiza o ambiente e publica; `scripts/destroy.sh`
  remove; `scripts/bootstrap-github-oidc.sh` prepara a integração com o GitHub;
  `scripts/estimate-cost.sh` calcula o custo pela AWS Pricing API.
- Idempotência por consulta antes de criar: cada recurso é procurado por nome
  e/ou tags (`Project=registro-app`, `Environment`, `Owner`, `ManagedBy=scripts`).
- Estado do laboratório no SSM (`/registro/<env>/state`: `provisioning`,
  `active`, `destroying`), usado pelo pipeline para saber se deve publicar.
- Funções compartilhadas em `scripts/lib/`: `aws_r` (leitura; "não encontrado"
  vira vazio), `aws_w` (escrita), `aws_wait`. Todas respeitam `--dry-run`.
- Políticas IAM/S3 geradas por funções puras em `scripts/lib/policies.sh`,
  testadas sem acesso à AWS.
- O workflow chama o mesmo `deploy.sh`: não existe uma segunda implementação.

## Consequências

- Sem estado de IaC, nada é removido em cascata: o `destroy.sh` apaga na ordem de
  dependência e confere remanescentes por identificador.
- `--dry-run` permitiu validar o fluxo inteiro antes da ativação da conta.
- Drift manual (alterações pelo console) não é detectado; os scripts só
  convergem os atributos que eles mesmos definem.
- Mais código a manter que uma stack declarativa; aceitável para o escopo.
