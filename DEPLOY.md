# Pipeline de deploy do laboratório com IA

Este arquivo define a sequência de trabalho que o agente deve conduzir: ler o
projeto, conversar sobre suas necessidades, decidir a infraestrutura e escrever
toda a automação de entrega. Os participantes vão evoluir estas instruções
durante o workshop.

A aplicação já tem API, frontend e PostgreSQL. O laboratório usa dados de teste
e recursos temporários na AWS. O objetivo é publicar a aplicação, comprovar uma
segunda entrega pelo pipeline e encerrar o ambiente com baixo custo.

Ao receber o pedido para seguir este arquivo, execute as fases abaixo em ordem.
Não pare na proposta: escreva os arquivos, valide a implementação e acompanhe
a execução dentro do escopo autorizado. Faça as perguntas necessárias antes
das decisões que dependem das respostas.

> **Obs.:** não use IaC (Terraform, CloudFormation, CDK, Pulumi, SAM ou
> similares). A infraestrutura deve ser criada e removida por scripts Bash
> com a AWS CLI, versionados no repositório.

| Fase | Trabalho do agente | Resultado esperado |
| --- | --- | --- |
| 1. Contexto | Confirmar as restrições do laboratório. | Conta, ambiente, orçamento e duração definidos. |
| 2. Descoberta | Investigar o código e entrevistar a pessoa. | Diagnóstico e requisitos registrados. |
| 3. Decisão | Propor arquitetura, custo e estratégia de publicação. | Plano de implementação revisado. |
| 4. Implementação | Escrever scripts, infraestrutura, testes e workflows. | CI/CD completo e verificações executadas. |
| 5. Demonstração | Publicar e comprovar uma atualização pela `main`. | Pessoa usando a aplicação atualizada na AWS. |
| 6. Encerramento | Perguntar se pode destruir e agir após a confirmação. | Recursos removidos e resultado conferido. |

O `DEPLOY.md` conduz o trabalho do agente. Os workflows em
`.github/workflows/` executam o CI/CD a cada evento configurado, sem depender
de uma nova conversa com a IA para publicar cada alteração.

## 1. Restrições iniciais

As definições abaixo são propostas para o laboratório. Confirme os valores com
o responsável antes de criar recursos.

| Item | Proposta inicial |
| --- | --- |
| Região | `us-east-1`, se a conta e as regras do evento permitirem. |
| Orçamento | Meta de até US$ 0,50 por ambiente e por sessão. |
| Duração | Planejamento de duas horas, com remoção após confirmação da pessoa. |
| Uso | Testes funcionais com poucos acessos, sem teste de carga. |
| API | Um serviço ECS com Fargate e uma task em regime normal. |
| Entrada da API | IPv4 público da própria task, sem ALB, API Gateway, NAT ou domínio. |
| Banco | RDS PostgreSQL Single-AZ, privado e sem réplica. |
| Frontend | Arquivos estáticos no S3 com Static Website Hosting (HTTP), sem CloudFront. |
| Imagem | Repositório privado no ECR, na região da API. |
| CI/CD | GitHub Actions, salvo padrão já definido pelo responsável. |
| Dados | Sintéticos e descartáveis ao final do laboratório. |

O orçamento é um critério para aprovar o plano, não uma estimativa validada nem
um bloqueio automático da cobrança. Não presuma créditos ou Free Tier. Calcule
o custo com preços vigentes, duração, uso e número de ambientes. Separe o custo
AWS de eventuais cobranças do agente de IA e do provedor de CI/CD.

ECS com Fargate executa a API. App Runner seria uma alternativa de hospedagem,
não um componente adicional obrigatório. Não o adote como base do workshop:
a AWS informa que o serviço deixou de aceitar novos clientes em 30 de abril
de 2026. Veja o [aviso oficial do App Runner][apprunner].

## 2. Descoberta da aplicação e entrevista

Leia as instruções do repositório e investigue o código antes de perguntar.
Identifique a stack de cada componente, gerenciadores de dependências e
lockfiles, comandos de build e teste, linters existentes, porta da API,
health check, variáveis necessárias e migrations. Examine testes e workflows
existentes e identifique as lacunas. Verifique se o frontend gera arquivos
estáticos e como recebe a URL da API. Não imprima valores de segredos.

Converse sobre as lacunas que mudam o deploy:

- Qual conta, perfil de acesso, região e identificador do grupo serão usados?
- Há preferência de hospedagem ou padrão obrigatório do time?
- Quantas pessoas vão acessar ao mesmo tempo e que operações vão executar?
- Há picos de acesso? Qual volume inicial de dados é esperado?
- Existem uploads, processos demorados, tarefas em segundo plano ou WebSockets?
- A sessão aceita uma breve interrupção durante a atualização da aplicação?
- O acesso será público ou restrito? Como a aplicação autentica seus usuários?
- Quanto tempo a pessoa precisa para testar e quem confirma o encerramento?
- Existe domínio e certificado disponíveis para a API, se a solução precisar?

Faça perguntas em pequenos grupos e explique como as respostas afetam o deploy.
Não pergunte novamente o que a pessoa já definiu nem o que o código esclarece.
Se ela não souber responder, apresente uma hipótese simples para o laboratório
e peça sua definição quando ela mudar o custo ou o comportamento esperado.

Registre fatos encontrados no código, respostas do responsável, decisões e
hipóteses pendentes em `docs/deploy-decisions.md`, sem segredos. Use esse registro
para retomar o trabalho sem repetir a entrevista. Não use ferramenta de IaC:
provisione com scripts Bash e AWS CLI, criando cada recurso de forma idempotente
(consulte antes de criar) e identificando-o por nome e tags do ambiente.

Conclua esta fase explicando o que a aplicação precisa, o que já existe e o que
será implementado. Se algum requisito não couber no orçamento do laboratório,
apresente o conflito antes de escolher a infraestrutura.

## 3. Proposta de infraestrutura e custo

Comece avaliando Fargate com 0,25 vCPU e 512 MiB ou 1 GiB de memória. Escolha
pela necessidade observada da API e valide o consumo. Verifique a arquitetura
da imagem Docker e sua compatibilidade com a task.

Para o banco, avalie `db.t4g.micro` e 20 GiB de armazenamento de uso geral.
Confirme disponibilidade da classe e compatibilidade da versão do PostgreSQL
na região. Mantenha acesso ao banco restrito às tasks autorizadas.

Esta é uma aplicação de testes: não use ALB, API Gateway, NAT Gateway,
Route 53, domínio ou qualquer outro serviço que só adicione custo. O navegador
acessa a API pelo IPv4 público da task Fargate, na porta da aplicação.

Esse IP muda a cada deploy e sempre que o ECS substitui a task. Por isso, o
deploy descobre o IP da task nova depois que ela fica saudável e só então gera
a configuração do frontend com essa URL. Use o health check do container para
o ECS e o circuit breaker decidirem se a task está saudável. Aceite a breve
indisponibilidade na troca do endereço e explique à pessoa que, se a task for
substituída fora de um deploy, o site só volta a achar a API depois de uma
nova execução do pipeline.

O frontend usa S3 Static Website Hosting, e não CloudFront. Contas novas podem
exigir verificação do AWS Support antes de criar distribuições CloudFront, o
que bloqueia o laboratório. Considere as consequências desse desenho:

- O endpoint do site S3 só serve HTTP, e a API no IP da task também fica em
  HTTP. Senhas e tokens trafegam sem criptografia, o que só é
  aceitável com os dados sintéticos do laboratório. Deixe isso explícito para
  a pessoa antes de publicar.
- O bucket precisa de leitura pública apenas para `s3:GetObject` nos objetos do
  site. Mantenha ACLs bloqueadas e a escrita restrita à role de deploy. Confira
  antes se o bloqueio de acesso público no nível da conta permite essa policy.
- O site e a API ficam em origens diferentes. O frontend recebe a URL pública
  da API por um arquivo de configuração gerado no deploy, e a API libera CORS
  somente para a origem do site.
- Não há camada de cache na frente do S3. Publique os arquivos com
  `Cache-Control` adequado para a versão nova aparecer sem invalidação.

Execute a task em sub-rede pública com IPv4 público, liberando apenas a porta
da API, e mantenha o RDS em sub-redes privadas, acessível só pelo security group
das tasks. Assim a task tem saída para ECR, SSM e logs sem NAT; o único custo
de rede é o IPv4 público. Veja as [opções de conectividade do ECS][network].

Não adicione alta disponibilidade, autoscaling, WAF, réplicas ou serviços
auxiliares pagos sem uma necessidade demonstrada e um orçamento atualizado.
Serviços necessários de identidade, segredos, logs e entrada da API precisam
aparecer no inventário, mesmo quando não estão na lista inicial.

Antes do provisionamento, apresente uma tabela com:

- Recurso, configuração, quantidade e tempo previsto de existência.
- Tarifa, unidade de cobrança, fonte oficial e data da consulta.
- Subtotal calculado por ferramenta e total por ambiente e por turma.
- Custos variáveis, incertezas e margem para repetições e remoção.

Inclua compute, banco, armazenamento, IPv4, imagens, requisições,
tráfego, logs e segredos. Considere tasks temporárias de migration e a eventual
sobreposição de tasks durante o deploy. Diferencie preço por hora de preço
por GB-mês. Não apresente um custo parcial como custo total.

Se faltar preço ou se a estimativa exceder a meta, explique a lacuna e proponha
um ajuste antes de criar recursos. Mostre também o impacto de deixar o ambiente
ligado por 24 horas. Um alerta de orçamento não garante desligamento imediato.

## 4. Implementação completa da entrega

Escreva os arquivos de container, infraestrutura, configuração, scripts shell,
testes e CI/CD necessários. Reutilize o que já estiver correto. A entrega inclui
os workflows executáveis e sua integração com a AWS, não apenas exemplos de
YAML ou uma lista de instruções para a pessoa implementar depois.

### Integração contínua

Configure a validação em pull requests destinados à `main` e em pushes na
`main`. Escolha ferramentas compatíveis com a stack encontrada e implemente:

1. Instalação reproduzível de dependências com os lockfiles do projeto.
2. Linters e verificação de formatação da API e do frontend.
3. Verificação de tipos quando aplicável à stack.
4. Testes automatizados da API e do frontend. Escreva os testes que faltarem
   para os comportamentos essenciais, com asserções sobre resultados reais.
5. Testes de integração com PostgreSQL descartável no CI, incluindo migrations
   e persistência, sem usar o banco do ambiente AWS como banco de testes do CI.
6. Validação dos scripts shell e das políticas IAM que eles geram, incluindo
   regras relevantes de configuração e acesso. Use `bash -n` e um linter de shell apropriado.
7. Build do frontend e da imagem Docker da API.

Adapte o conjunto de testes à aplicação. Não crie testes que apenas confirmem
que um arquivo existe e não desative uma verificação para obter sucesso.
Quando uma ferramenta não se aplicar, registre a razão e a verificação que
cobre aquela necessidade. Falhas obrigatórias devem impedir a publicação.

### Entrega contínua pela branch `main`

Um push na `main`, inclusive o produzido por merge de um pull request, deve
iniciar o pipeline. Com o ambiente ativo e todas as verificações obrigatórias
aprovadas, publique automaticamente a versão correspondente àquele commit na
AWS. A pessoa não deve precisar executar um segundo deploy local ou pedir
novamente à IA para atualizar o sistema.

Implemente a sequência:

1. Execute os testes, linters, validações e builds do commit recebido.
2. Faça os jobs de publicação dependerem explicitamente do sucesso dessas
   etapas, usando dependências entre jobs ou workflows reutilizáveis.
3. Autentique na AWS por OIDC, com confiança restrita ao repositório e ao
   contexto reais. Prepare o bootstrap necessário com o acesso autorizado.
4. Publique no ECR a imagem validada e identifique-a pelo commit ou digest.
   Faça o deploy consumir exatamente esse artefato.
5. Execute migrations como etapa única, com acesso ao RDS privado, e confira
   o código de saída. Interrompa o deploy se a migration falhar. Não dependa
   de acesso direto do runner público ao RDS nem rode migrations em cada
   réplica da API. Preserve compatibilidade entre o schema e as versões.
6. Atualize o serviço ECS e aguarde sua estabilidade. Para o frontend, publique
   o build validado no bucket do S3 Static Website com `Cache-Control` que
   exiba a versão nova. Gere no deploy a configuração pública com a URL da API.
7. Execute uma verificação funcional após o deploy e registre o commit
   publicado, a URL, o resultado e eventuais falhas no resumo do workflow.

Controle concorrência por ambiente para evitar atualizações sobrepostas.
Não coloque credenciais permanentes no código nem segredos no bundle público
do frontend. Configure as variáveis, permissões e referências a segredos de
que os workflows precisam. Informe claramente qualquer configuração que
dependa de acesso ainda indisponível, sem marcar a integração como concluída.

Use um acionamento explícito para o primeiro provisionamento. Os pushes na
`main` atualizam o ambiente já ativo. Depois da destruição confirmada, os
workflows devem informar que o laboratório está encerrado e não recriar os
recursos. Um novo provisionamento exige um acionamento explícito. Mudanças
exclusivamente documentais podem dispensar a etapa de deploy, sem ocultar
validações obrigatórias.

Execute as verificações relevantes localmente durante a implementação e
acompanhe também uma execução real no provedor de CI/CD. A validação local
sozinha não comprova que credenciais, permissões e dependências do runner
funcionam.

Apresente o diff e o plano de recursos para revisão. Registre o escopo autorizado
para criar e atualizar este ambiente. A confirmação para destruir vem depois
que a pessoa tiver oportunidade de usar a aplicação, conforme a seção 6.
Execute dentro desse escopo e relate falhas com saídas reais das ferramentas.

### Scripts shell obrigatórios

Escreva e versione os scripts abaixo no repositório. O `DEPLOY.md` orienta o
agente; os arquivos `.sh` executam as operações de infraestrutura. Reutilize os
scripts existentes quando cumprirem estas responsabilidades.

| Arquivo | Responsabilidade |
| --- | --- |
| `scripts/deploy.sh` | Criar ou atualizar o ambiente, executar as etapas de publicação, verificar o resultado e apresentar a URL da aplicação. |
| `scripts/destroy.sh` | Remover os recursos exclusivos do ambiente, aguardar a conclusão e informar qualquer recurso remanescente. |

Os scripts devem:

- Usar Bash, declarar o interpretador e ter permissão de execução.
- Receber explicitamente o ambiente e a região. Validar a conta AWS esperada
  usando a identidade autenticada. Aceitar perfil local quando aplicável e
  credenciais temporárias do pipeline, sem armazenar credenciais no código.
- Usar a AWS CLI, sem ferramenta de IaC, e reutilizar as mesmas operações no
  CI/CD, evitando duas implementações divergentes do mesmo deploy.
- Verificar dependências e argumentos antes de iniciar as alterações.
- Tratar falhas e retornar código de saída diferente de zero quando uma etapa
  obrigatória falhar. Não imprimir sucesso após uma execução incompleta.
- Permitir nova execução para o mesmo ambiente sem duplicar recursos.
  A destruição deve tolerar recursos já removidos e relatar falhas reais.
- Identificar os recursos pelo ambiente e preservar recursos compartilhados.
- Documentar os comandos de uso e validar a sintaxe com `bash -n`.

O `deploy.sh` deve apresentar o endereço para acesso e o resultado das
verificações. O `destroy.sh` deve informar que remove também os dados de teste
e pedir confirmação quando executado diretamente pela pessoa. Permita uma
opção não interativa para o agente executar após receber a confirmação na
conversa, sem pedir a mesma autorização novamente. Documente essa opção.

Gerar o `destroy.sh` faz parte da preparação. Executá-lo depende da confirmação
de encerramento. O `deploy.sh` não deve chamar a destruição automaticamente ao
terminar, inclusive em blocos de limpeza ou tratamento de erro.

## 5. Evidências de sucesso

A etapa de publicação está concluída quando o grupo comprova que:

- O navegador carrega o frontend e acessa a API pelo caminho definido.
- É possível criar e consultar um registro persistido no banco.
- Um push com alteração válida na `main` executa o CI/CD e atualiza a aplicação
  em execução na AWS, sem um deploy local complementar.
- O workflow bloqueia a publicação quando testes, linters, validações ou build
  falham. Uma falha controlada de teste demonstra o bloqueio e a preservação
  da última versão publicada.
- Uma nova entrega preserva os dados de teste enquanto o ambiente está ativo.
- O repositório explica como consultar logs e recuperar uma entrega falha.

Combine com a pessoa uma pequena alteração visível, como um texto na interface.
Faça a alteração pelo fluxo de Git autorizado, acompanhe a execução iniciada
na `main` e confira a mudança na URL pública. Relacione o commit, a execução do
pipeline e a versão servida. Use apenas o ambiente de laboratório para a
demonstração de falha e restaure o teste depois de verificar o bloqueio.

Mostre a URL e um roteiro curto para a pessoa testar: abrir o frontend, criar
um registro, consultar os dados e conferir a nova versão. Mantenha o ambiente
disponível enquanto ela experimenta. Passar nos testes automáticos não
substitui essa oportunidade de ver a aplicação funcionando.

Quando uma hipótese de diagnóstico falhar repetidamente, procure uma nova
evidência antes de tentar outra alteração. Reverter a aplicação não desfaz
migrations nem restaura os dados do banco.

## 6. Encerramento e conferência

Prepare o `scripts/destroy.sh` junto com o `scripts/deploy.sh`. Use
identificadores únicos por grupo e registre os recursos pertencentes ao
laboratório. Inclua tags de ambiente e responsável onde o serviço permitir.

Depois de apresentar a aplicação funcionando e permitir que a pessoa teste,
pergunte explicitamente:

> Você já conseguiu testar a aplicação? Posso destruir o ambiente do
> laboratório e apagar os dados de teste agora?

Aguarde uma resposta afirmativa antes de executar o `scripts/destroy.sh`.
Se a pessoa quiser continuar, mantenha o ambiente disponível. Se ela não
responder ou se a sessão terminar, não presuma autorização para destruir.
Informe que os recursos continuam ativos e deixe o comando de encerramento
manual disponível.

Após a confirmação, execute o script para o ambiente identificado, acompanhe
a remoção e apresente o resultado. Não exija que a pessoa execute os comandos
manualmente nem repita a confirmação para o mesmo escopo já autorizado.

A duração planejada e a meta de custo não autorizam encerramento automático.
Se a pessoa prolongar a sessão, explique o impacto estimado no custo. Não
configure destruição por prazo ou por inatividade como padrão deste laboratório.

Para os dados descartáveis deste exercício, proponha explicitamente a política
de exclusão do RDS e de seus backups, como `--skip-final-snapshot`,
`--delete-automated-backups` e retenção de backup zero. Sem uma stack de IaC,
nada é removido em cascata: o `destroy.sh` precisa apagar cada recurso na ordem
de dependência e conferir snapshots ou recursos retidos. Nunca aplique uma política destrutiva aos dados
de outro ambiente. Veja as [opções de exclusão do RDS][rds-delete].

Depois da remoção, confira por identificador os recursos remanescentes: banco,
snapshots, backups retidos, tasks, balanceadores, IPs, imagens, buckets, versões
de objetos, configuração de website, segredos e logs. Preserve recursos compartilhados
que já existiam. Informe resíduos, falhas de exclusão e custos possíveis.

O faturamento pode aparecer depois. Diferencie a conferência imediata dos
recursos de uma confirmação posterior das cobranças.

## Referências

As referências foram consultadas em 23 de setembro de 2026. Confirme preços e
disponibilidade novamente na preparação de cada workshop.

- [Preços do Fargate][fargate].
- [Preços do RDS PostgreSQL][rds].
- [Preços de rede e IPv4][vpc].
- [Preços do Elastic Load Balancing][elb].
- [Preços do ECR][ecr].
- [Preços do S3][s3] e [S3 Static Website Hosting][s3-website].
- [Autenticação GitHub Actions com OIDC na AWS][oidc].
- [Dependências entre jobs do GitHub Actions][jobs].

[apprunner]: https://aws.amazon.com/apprunner/
[network]: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/networking-outbound.html
[fargate]: https://aws.amazon.com/fargate/pricing/
[rds]: https://aws.amazon.com/rds/postgresql/pricing/
[vpc]: https://aws.amazon.com/vpc/pricing/
[elb]: https://aws.amazon.com/elasticloadbalancing/pricing/
[ecr]: https://aws.amazon.com/ecr/pricing/
[s3]: https://aws.amazon.com/s3/pricing/
[s3-website]: https://docs.aws.amazon.com/AmazonS3/latest/userguide/WebsiteHosting.html
[rds-delete]: https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_DeleteInstance.html
[oidc]: https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-aws
[jobs]: https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-jobs
