# 0012. Alerta de orçamento de US$ 2 por mês

- Status: Aceito
- Data: 2026-09-24

## Contexto

A aplicação existe só para o workshop e não deve gerar custo contínuo. O risco
principal é esquecer o `destroy.sh`: o ambiente parado custa ~US$ 0,04/h
(~US$ 1/dia, a maior parte RDS). O ADR 0010 proíbe destruição automática por
prazo ou inatividade.

## Decisão

- Budget mensal de custo `workshop-limite-2usd` (US$ 2) no AWS Budgets, na conta
  270244457878, com e-mail para o responsável quando:
  - o custo **real** do mês passar de 100% (US$ 2);
  - o custo **previsto** do mês passar de 100%.
- `IncludeCredit=false`: os créditos promocionais não abatem o valor monitorado,
  para o alerta disparar pelo uso real mesmo enquanto os créditos cobrem a fatura.
- Criado uma vez pela AWS CLI, fora dos scripts do ambiente: é da conta, não do
  ambiente `lab-lizzard`, e não é removido pelo `destroy.sh`.

## Consequências

- O alerta só avisa, não desliga nada. A ação continua sendo o `destroy.sh`.
- O AWS Budgets atualiza os custos algumas vezes por dia: o aviso pode chegar
  horas depois do gasto.
- Budgets de monitoramento não têm custo.
- Para remover depois do workshop:
  `aws budgets delete-budget --account-id 270244457878 --budget-name workshop-limite-2usd`.
