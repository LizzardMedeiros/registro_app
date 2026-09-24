# 0005. Banco RDS PostgreSQL Single-AZ privado e descartável

- Status: Aceito
- Data: 2026-09-24

## Contexto

A aplicação usa PostgreSQL 16 (tabela `users`, migrations em
`api/migrations/` aplicadas por `src/migrate.js`). Os dados do laboratório são
sintéticos e devem ser apagados no encerramento.

## Decisão

- RDS PostgreSQL 16 (maior versão 16.x disponível para a classe na região,
  consultada no deploy), `db.t4g.micro`, 20 GiB gp3, Single-AZ, criptografado.
- Sub-redes privadas em duas AZs (exigência do subnet group), sem rota para a
  internet; `--no-publicly-accessible`; ingresso na 5432 só do SG da API.
- TLS verificado com o bundle de CA da AWS (`DB_SSL=true`), já embutido na imagem.
- Política de dados descartáveis: `--backup-retention-period 0`,
  `--no-deletion-protection`; na destruição, `--skip-final-snapshot` e
  `--delete-automated-backups`, além de remover snapshots manuais do mesmo banco.
- Migrations como task única do ECS (mesma imagem, comando `node src/migrate.js`),
  com exit code verificado antes de atualizar o serviço.

## Consequências

- Sem backups: um erro destrói os dados de teste sem recuperação (aceito).
- O runner do GitHub nunca acessa o RDS diretamente.
- Reverter a aplicação não desfaz migrations: mudanças de schema precisam ser
  compatíveis com a versão anterior (expandir antes de contrair).
- O RDS é o maior custo por hora e cobra enquanto existir, mesmo ocioso.
