# 0010. Ciclo de vida: provisionamento explícito e destruição confirmada

- Status: Aceito
- Data: 2026-09-24

## Contexto

Pushes na `main` não devem recriar um ambiente destruído. A destruição apaga
dados e só pode acontecer com confirmação do responsável. Prazo ou inatividade
não autorizam encerramento automático.

## Decisão

- Primeiro provisionamento só por acionamento explícito: `workflow_dispatch` com
  `action=provision`, ou `deploy.sh --provision` localmente.
- Pushes na `main` só atualizam um ambiente com estado `active`; caso contrário o
  deploy termina com sucesso, informando "laboratório não está ativo".
- `destroy.sh` pede que se digite o nome do ambiente; `--yes` é a opção não
  interativa para o agente, depois da confirmação na conversa. Sem terminal e
  sem `--yes`, recusa.
- A primeira ação da destruição é marcar o estado `destroying`, para os pushes
  pararem de publicar. Em seguida remove, em ordem: ECS, RDS (sem snapshot final
  e sem backups), ECR, S3 (objetos e versões), logs, role de execução, segredos,
  rede (esperando as ENIs sumirem) e, por último, o parâmetro de estado.
- No fim, confere remanescentes por identificador e sai com erro se algo sobrou.
- O `deploy.sh` nunca chama a destruição, nem em tratamento de erro.

## Consequências

- Se ninguém confirmar, o ambiente continua ativo e gerando custo (~US$ 0,04/h,
  ~US$ 0,89 em 24 h): o encerramento manual fica documentado em
  `docs/operations.md`.
- O faturamento pode aparecer depois da remoção; a conferência imediata não
  substitui a revisão da fatura.
