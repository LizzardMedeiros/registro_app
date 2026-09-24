# 0004. API no ECS Fargate com IPv4 público, sem ALB

- Status: Aceito
- Data: 2026-09-24

## Contexto

A API (Node 22 + Express, porta 3000, `GET /api/health`) é stateless e leve.
Uso esperado: o responsável e poucas pessoas, testes manuais. A meta de custo é
US$ 0,50 por sessão. O App Runner deixou de aceitar novos clientes em
30/04/2026. ALB, API Gateway, NAT e domínio só adicionariam custo.

## Decisão

- ECS Fargate, 1 task, 0,25 vCPU e 512 MiB, `X86_64` (imagem construída em runner
  amd64).
- Task em sub-rede pública com `assignPublicIp=ENABLED`; o security group libera
  apenas a porta 3000. Saída para ECR, SSM e CloudWatch pela internet, sem NAT.
- Deploy com `minimumHealthyPercent=0` e `maximumPercent=100`: a task antiga
  para antes da nova subir (breve indisponibilidade aceita), sem pagar duas tasks.
- Circuit breaker com rollback; health check do container em `/api/health`.
- O deploy acompanha `rolloutState` da deployment PRIMARY até `COMPLETED` e
  confere se ela usa a task definition nova (o waiter `services-stable` pode
  retornar antes e não detecta rollback).
- Depois do rollout, o deploy descobre o IP público da task nova e só então gera
  a configuração do frontend.

## Consequências

- O IP muda a cada deploy e sempre que o ECS substitui a task. Se a task for
  substituída fora de um deploy, o site só volta a achar a API depois de uma
  nova execução do pipeline (workflow_dispatch `deploy`).
- API em HTTP puro (ver ADR 0006).
- Sem alta disponibilidade nem autoscaling: uma falha de AZ derruba a API.
