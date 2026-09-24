#!/usr/bin/env bash
# Cria ou atualiza o ambiente do laboratório na AWS e publica a aplicação.
#
# Uso:
#   scripts/deploy.sh --env NOME --region REGIAO --account CONTA --image-tag TAG [opções]
#
# Opções:
#   --profile PERFIL      Perfil local da AWS CLI (omitir no CI: usa credenciais OIDC)
#   --provision           Permite criar o ambiente se ele não estiver ativo
#   --local-image IMAGEM  Imagem Docker local (ex.: registro-api:abc123) a enviar ao ECR com TAG
#   --owner NOME          Valor da tag Owner (padrão: usuário local ou ator do GitHub)
#   --dry-run             Mostra o que seria feito, sem alterar a conta
#
# Exemplos:
#   docker build -t registro-api:dev api
#   scripts/deploy.sh --env lab-lizzard --region us-east-1 --account 270244457878 \
#     --profile personal --provision --image-tag dev --local-image registro-api:dev
#
# Sem --provision, o script só atualiza um ambiente ativo; se o laboratório foi
# encerrado (ou nunca criado), ele informa e sai com sucesso sem criar nada.
# Este script nunca destrói recursos: use scripts/destroy.sh.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/policies.sh
source "$SCRIPT_DIR/lib/policies.sh"

usage() {
  sed -n '2,22p' "$0" >&2
  exit 2
}

ENV_NAME='' ACCOUNT='' IMAGE_TAG='' LOCAL_IMAGE='' PROVISION=false
OWNER="${GITHUB_ACTOR:-${USER:-unknown}}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) ENV_NAME="${2:-}"; shift 2 ;;
    --region) REGION="${2:-}"; shift 2 ;;
    --account) ACCOUNT="${2:-}"; shift 2 ;;
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --image-tag) IMAGE_TAG="${2:-}"; shift 2 ;;
    --local-image) LOCAL_IMAGE="${2:-}"; shift 2 ;;
    --owner) OWNER="${2:-}"; shift 2 ;;
    --provision) PROVISION=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h | --help) usage ;;
    *) echo "Argumento desconhecido: $1" >&2; usage ;;
  esac
done

[[ -n "$ENV_NAME" && -n "$REGION" && -n "$ACCOUNT" && -n "$IMAGE_TAG" ]] || usage
validate_env_name "$ENV_NAME"
validate_region "$REGION"
validate_account "$ACCOUNT"
[[ "$IMAGE_TAG" =~ ^[A-Za-z0-9._-]{1,128}$ ]] || die "Tag de imagem inválida: $IMAGE_TAG"
need aws jq curl openssl
[[ -z "$LOCAL_IMAGE" ]] || need docker

# ---- Configuração do ambiente ------------------------------------------------
PREFIX="registro-${ENV_NAME}"
VPC_CIDR=10.42.0.0/16
PUBLIC_CIDR=10.42.0.0/24
PRIVATE_CIDRS=(10.42.10.0/24 10.42.11.0/24)
API_PORT=3000
TASK_CPU=256
TASK_MEMORY=512
DB_CLASS=db.t4g.micro
DB_STORAGE=20
DB_ENGINE_MAJOR=16
DB_NAME=registro
DB_USER=app
DB_ID="${PREFIX}-db"
CLUSTER="${PREFIX}"
SERVICE="${PREFIX}-api"
FAMILY="${PREFIX}-api"
REPO="${PREFIX}-api"
LOG_GROUP="/ecs/${PREFIX}"
EXEC_ROLE="${PREFIX}-ecs-exec"
BUCKET="${PREFIX}-${ACCOUNT}-site"
SITE_URL="http://${BUCKET}.s3-website-${REGION}.amazonaws.com"
PARAM_PREFIX="/registro/${ENV_NAME}"
ROLLOUT_TIMEOUT=900

log "Ambiente $ENV_NAME | região $REGION | conta $ACCOUNT | imagem $IMAGE_TAG | dry-run=$DRY_RUN"
check_identity "$ACCOUNT"

# ---- Estado do laboratório -----------------------------------------------------
STATE=$(get_state)
if [[ "$STATE" == destroying ]]; then
  die "Ambiente '$ENV_NAME' em destruição (ou destruição incompleta). Termine com scripts/destroy.sh antes de publicar ou provisionar."
fi
if [[ "$STATE" != active && "$PROVISION" != true ]]; then
  msg="Laboratório '$ENV_NAME' não está ativo (estado: ${STATE:-inexistente}). Nada foi criado. Para provisionar, rode com --provision (no GitHub: workflow_dispatch com action=provision)."
  log "$msg"
  summary "### Deploy ignorado" "" "$msg"
  exit 0
fi
[[ "$STATE" == active ]] || set_state provisioning

# ---- Rede ------------------------------------------------------------------------
find_by_name() { # recurso ec2 (vpc|subnet|...) e Name
  local kind="$1" name="$2" query="$3"
  aws_r ec2 "describe-${kind}" --filters "Name=tag:Name,Values=${name}" "Name=tag:Environment,Values=${ENV_NAME}" \
    --query "$query" --output text | sed 's/^None$//'
}

ensure_network() {
  log "Rede (VPC, sub-redes, internet gateway)"
  VPC_ID=$(find_by_name vpcs "${PREFIX}-vpc" 'Vpcs[0].VpcId')
  if [[ -z "$VPC_ID" ]]; then
    VPC_ID=$(aws_w ec2 create-vpc --cidr-block "$VPC_CIDR" \
      --tag-specifications "$(ec2_tagspec vpc "${PREFIX}-vpc")" --query Vpc.VpcId --output text)
    [[ "$DRY_RUN" == true ]] || aws_wait ec2 wait vpc-available --vpc-ids "$VPC_ID"
    aws_w ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames '{"Value":true}' >/dev/null
    log "VPC criada: $VPC_ID"
  fi

  mapfile -t AZS < <(aws_r ec2 describe-availability-zones --filters Name=state,Values=available \
    Name=zone-type,Values=availability-zone --query 'sort(AvailabilityZones[].ZoneName)[:2]' --output text | tr '\t' '\n')
  [[ ${#AZS[@]} -ge 2 && -n "${AZS[0]}" ]] || { [[ "$DRY_RUN" == true ]] && AZS=("${REGION}a" "${REGION}b"); } ||
    die "Não encontrei duas AZs disponíveis em $REGION"

  IGW_ID=$(find_by_name internet-gateways "${PREFIX}-igw" 'InternetGateways[0].InternetGatewayId')
  if [[ -z "$IGW_ID" ]]; then
    IGW_ID=$(aws_w ec2 create-internet-gateway \
      --tag-specifications "$(ec2_tagspec internet-gateway "${PREFIX}-igw")" \
      --query InternetGateway.InternetGatewayId --output text)
    aws_w ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" >/dev/null
  fi

  PUBLIC_SUBNET=$(ensure_subnet "${PREFIX}-public" "$PUBLIC_CIDR" "${AZS[0]}")
  PRIVATE_SUBNETS=()
  local i
  for i in 0 1; do
    PRIVATE_SUBNETS+=("$(ensure_subnet "${PREFIX}-private-$i" "${PRIVATE_CIDRS[$i]}" "${AZS[$i]}")")
  done

  RT_ID=$(find_by_name route-tables "${PREFIX}-public-rt" 'RouteTables[0].RouteTableId')
  if [[ -z "$RT_ID" ]]; then
    RT_ID=$(aws_w ec2 create-route-table --vpc-id "$VPC_ID" \
      --tag-specifications "$(ec2_tagspec route-table "${PREFIX}-public-rt")" --query RouteTable.RouteTableId --output text)
    aws_w ec2 create-route --route-table-id "$RT_ID" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" >/dev/null
    aws_w ec2 associate-route-table --route-table-id "$RT_ID" --subnet-id "$PUBLIC_SUBNET" >/dev/null
  fi
  # Sub-redes privadas ficam na route table principal (só rota local): sem saída para a internet.
}

ensure_subnet() { # nome cidr az -> id
  local name="$1" cidr="$2" az="$3" id
  id=$(find_by_name subnets "$name" 'Subnets[0].SubnetId')
  if [[ -z "$id" ]]; then
    id=$(aws_w ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$cidr" --availability-zone "$az" \
      --tag-specifications "$(ec2_tagspec subnet "$name")" --query Subnet.SubnetId --output text)
  fi
  printf '%s' "$id"
}

ensure_sg() { # nome descrição -> id
  local name="$1" desc="$2" id
  id=$(aws_r ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$name" \
    --query 'SecurityGroups[0].GroupId' --output text | sed 's/^None$//')
  if [[ -z "$id" ]]; then
    id=$(aws_w ec2 create-security-group --vpc-id "$VPC_ID" --group-name "$name" --description "$desc" \
      --tag-specifications "$(ec2_tagspec security-group "$name")" --query GroupId --output text)
  fi
  printf '%s' "$id"
}

allow_ingress() { # sg args... (idempotente: ignora regra duplicada)
  local sg="$1" out
  shift
  if [[ "$DRY_RUN" == true ]]; then
    aws_w ec2 authorize-security-group-ingress --group-id "$sg" "$@" >/dev/null
    return 0
  fi
  if ! out=$(aws_w ec2 authorize-security-group-ingress --group-id "$sg" "$@" 2>&1); then
    grep -q InvalidPermission.Duplicate <<<"$out" || die "Falha ao liberar ingresso em $sg: $out"
  fi
}

ensure_security_groups() {
  log "Security groups (API pública na porta $API_PORT; banco só a partir da API)"
  SG_API=$(ensure_sg "${PREFIX}-api-sg" "API registro ${ENV_NAME}: porta ${API_PORT} publica")
  SG_DB=$(ensure_sg "${PREFIX}-db-sg" "RDS registro ${ENV_NAME}: somente a partir da API")
  allow_ingress "$SG_API" --protocol tcp --port "$API_PORT" --cidr 0.0.0.0/0
  allow_ingress "$SG_DB" --protocol tcp --port 5432 --source-group "$SG_API"
}

# ---- Imagem ------------------------------------------------------------------------
ensure_ecr() {
  log "Repositório ECR $REPO"
  REPO_URI=$(aws_r ecr describe-repositories --repository-names "$REPO" \
    --query 'repositories[0].repositoryUri' --output text | sed 's/^None$//')
  if [[ -z "$REPO_URI" ]]; then
    aws_w ecr create-repository --repository-name "$REPO" --image-tag-mutability IMMUTABLE \
      --tags "$(tags_json)" >/dev/null
    # Mantém só as 5 imagens mais recentes
    aws_w ecr put-lifecycle-policy --repository-name "$REPO" --lifecycle-policy-text \
      '{"rules":[{"rulePriority":1,"selection":{"tagStatus":"any","countType":"imageCountMoreThan","countNumber":5},"action":{"type":"expire"}}]}' >/dev/null
  fi
  REPO_URI="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/${REPO}"
  IMAGE_URI="${REPO_URI}:${IMAGE_TAG}"
}

push_image() {
  local exists
  exists=$(aws_r ecr describe-images --repository-name "$REPO" --image-ids "imageTag=$IMAGE_TAG" \
    --query 'imageDetails[0].imageDigest' --output text | sed 's/^None$//')
  if [[ -n "$exists" ]]; then
    log "Imagem $IMAGE_TAG já está no ECR ($exists)"
  elif [[ -n "$LOCAL_IMAGE" ]]; then
    log "Enviando $LOCAL_IMAGE para $IMAGE_URI"
    if [[ "$DRY_RUN" == true ]]; then
      warn "dry-run: docker tag/push de $LOCAL_IMAGE omitidos"
    else
      aws --region "$REGION" ${PROFILE:+--profile "$PROFILE"} ecr get-login-password |
        docker login --username AWS --password-stdin "${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com" >/dev/null
      docker tag "$LOCAL_IMAGE" "$IMAGE_URI"
      docker push "$IMAGE_URI" >/dev/null
    fi
  elif [[ "$DRY_RUN" != true ]]; then
    die "Imagem $IMAGE_TAG não existe no ECR e nenhuma --local-image foi informada"
  fi
  if [[ "$DRY_RUN" != true ]]; then
    IMAGE_DIGEST=$(aws_r ecr describe-images --repository-name "$REPO" --image-ids "imageTag=$IMAGE_TAG" \
      --query 'imageDetails[0].imageDigest' --output text)
    # O deploy usa o digest: exatamente o artefato validado, mesmo que a tag mude.
    IMAGE_URI="${REPO_URI}@${IMAGE_DIGEST}"
    log "Imagem publicada: $IMAGE_URI"
  fi
}

# ---- Segredos, logs e IAM ----------------------------------------------------------------
ensure_secret() { # nome -> gera valor aleatório só na primeira vez
  local name="$PARAM_PREFIX/$1" exists
  exists=$(aws_r ssm describe-parameters --parameter-filters "Key=Name,Values=$name" \
    --query 'Parameters[0].Name' --output text | sed 's/^None$//')
  if [[ -z "$exists" ]]; then
    aws_w ssm put-parameter --name "$name" --type SecureString --value "$(openssl rand -hex 24)" \
      --tags "$(tags_json)" >/dev/null
    log "Segredo criado: $name"
  fi
}

ensure_secrets() {
  log "Segredos no SSM Parameter Store ($PARAM_PREFIX/*)"
  ensure_secret db-password
  ensure_secret jwt-secret
}

ensure_logs() {
  local exists
  exists=$(aws_r logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" \
    --query "logGroups[?logGroupName=='$LOG_GROUP'] | [0].logGroupName" --output text | sed 's/^None$//')
  if [[ -z "$exists" ]]; then
    aws_w logs create-log-group --log-group-name "$LOG_GROUP" \
      --tags "Project=$PROJECT,Environment=$ENV_NAME,Owner=$OWNER,ManagedBy=scripts" >/dev/null
  fi
  aws_w logs put-retention-policy --log-group-name "$LOG_GROUP" --retention-in-days 1 >/dev/null
}

ensure_exec_role() {
  log "Role de execução do ECS $EXEC_ROLE"
  local exists
  exists=$(aws_r iam get-role --role-name "$EXEC_ROLE" --query Role.Arn --output text)
  if [[ -z "$exists" ]]; then
    aws_w iam create-role --role-name "$EXEC_ROLE" \
      --assume-role-policy-document "$(policy_ecs_exec_trust "$ACCOUNT")" --tags "$(tags_json)" >/dev/null
    aws_w iam attach-role-policy --role-name "$EXEC_ROLE" \
      --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy >/dev/null
  fi
  aws_w iam put-role-policy --role-name "$EXEC_ROLE" --policy-name read-env-secrets \
    --policy-document "$(policy_ecs_exec_ssm "$ACCOUNT" "$REGION" "$ENV_NAME")" >/dev/null
  if [[ -z "$exists" && "$DRY_RUN" != true ]]; then
    aws_wait iam wait role-exists --role-name "$EXEC_ROLE"
    sleep 10 # propagação do IAM antes do ECS assumir a role
  fi
  EXEC_ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/${EXEC_ROLE}"

  # Contas novas podem não ter a service-linked role do ECS ainda.
  if [[ -z "$(aws_r iam get-role --role-name AWSServiceRoleForECS --query Role.Arn --output text)" ]]; then
    aws_w iam create-service-linked-role --aws-service-name ecs.amazonaws.com >/dev/null || true
  fi
}

# ---- Frontend: bucket S3 website -------------------------------------------------------
ensure_bucket() {
  log "Bucket do site $BUCKET"
  local acct_block
  acct_block=$(aws_r s3control get-public-access-block --account-id "$ACCOUNT" \
    --query 'PublicAccessBlockConfiguration.BlockPublicPolicy' --output text)
  if [[ "$acct_block" == True || "$acct_block" == true ]]; then
    die "O bloqueio de acesso público da CONTA impede policy pública no bucket. Ajuste em S3 > Block Public Access (conta) e rode de novo."
  fi

  # head-bucket: 404 vira vazio; 403 (nome em uso por outra conta) aborta.
  if [[ -z "$(aws_r s3api head-bucket --bucket "$BUCKET" --query BucketRegion --output text)" ]]; then
    if [[ "$REGION" == us-east-1 ]]; then
      aws_w s3api create-bucket --bucket "$BUCKET" --object-ownership BucketOwnerEnforced >/dev/null
    else
      aws_w s3api create-bucket --bucket "$BUCKET" --object-ownership BucketOwnerEnforced \
        --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
    fi
    aws_w s3api put-bucket-tagging --bucket "$BUCKET" --tagging "{\"TagSet\":$(tags_json)}" >/dev/null
  fi
  # ACLs continuam bloqueadas; apenas a policy pública de leitura é permitida.
  aws_w s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=false,RestrictPublicBuckets=false >/dev/null
  aws_w s3api put-bucket-policy --bucket "$BUCKET" --policy "$(policy_site_bucket "$BUCKET")" >/dev/null
  aws_w s3api put-bucket-website --bucket "$BUCKET" --website-configuration \
    '{"IndexDocument":{"Suffix":"index.html"},"ErrorDocument":{"Key":"index.html"}}' >/dev/null
}

# ---- Banco -------------------------------------------------------------------------------
ensure_db() {
  log "RDS PostgreSQL $DB_ID ($DB_CLASS, ${DB_STORAGE} GiB, Single-AZ, privado)"
  local subnet_group="${PREFIX}-db-subnets" status version
  if [[ -z "$(aws_r rds describe-db-subnet-groups --db-subnet-group-name "$subnet_group" \
    --query 'DBSubnetGroups[0].DBSubnetGroupName' --output text)" ]]; then
    aws_w rds create-db-subnet-group --db-subnet-group-name "$subnet_group" \
      --db-subnet-group-description "Sub-redes privadas do RDS registro ${ENV_NAME}" \
      --subnet-ids "${PRIVATE_SUBNETS[@]}" --tags "$(tags_json)" >/dev/null
  fi

  status=$(aws_r rds describe-db-instances --db-instance-identifier "$DB_ID" \
    --query 'DBInstances[0].DBInstanceStatus' --output text)
  if [[ -z "$status" ]]; then
    version=$(aws_r rds describe-orderable-db-instance-options --engine postgres --db-instance-class "$DB_CLASS" \
      --query "OrderableDBInstanceOptions[?starts_with(EngineVersion, '${DB_ENGINE_MAJOR}.')].EngineVersion" \
      --output json | jq -r 'unique | sort_by(split(".") | map(tonumber)) | last // empty')
    [[ -n "$version" ]] || { [[ "$DRY_RUN" == true ]] && version="${DB_ENGINE_MAJOR}.x"; } ||
      die "$DB_CLASS não suporta PostgreSQL $DB_ENGINE_MAJOR em $REGION"
    local password
    password=$(aws_r ssm get-parameter --name "$PARAM_PREFIX/db-password" --with-decryption \
      --query Parameter.Value --output text)
    [[ -n "$password" || "$DRY_RUN" == true ]] || die "Segredo $PARAM_PREFIX/db-password ausente"
    log "Criando banco (PostgreSQL $version); leva de 5 a 10 minutos"
    # Dados sintéticos: sem backups automáticos e sem proteção contra exclusão (ADR 0005).
    aws_w rds create-db-instance --db-instance-identifier "$DB_ID" --db-instance-class "$DB_CLASS" \
      --engine postgres --engine-version "$version" --allocated-storage "$DB_STORAGE" --storage-type gp3 \
      --master-username "$DB_USER" --master-user-password "${password:-dry-run}" --db-name "$DB_NAME" \
      --db-subnet-group-name "$subnet_group" --vpc-security-group-ids "$SG_DB" \
      --no-publicly-accessible --no-multi-az --backup-retention-period 0 --no-deletion-protection \
      --storage-encrypted --no-enable-performance-insights --monitoring-interval 0 \
      --tags "$(tags_json)" >/dev/null
  elif [[ "$status" != available ]]; then
    log "Banco em estado '$status'; aguardando"
  fi
  aws_wait rds wait db-instance-available --db-instance-identifier "$DB_ID"
  DB_HOST=$(aws_r rds describe-db-instances --db-instance-identifier "$DB_ID" \
    --query 'DBInstances[0].Endpoint.Address' --output text | sed 's/^None$//')
  DB_HOST=${DB_HOST:-dryrun.rds.amazonaws.com}
}

# ---- ECS ---------------------------------------------------------------------------------
ensure_cluster() {
  local status
  status=$(aws_r ecs describe-clusters --clusters "$CLUSTER" --query 'clusters[0].status' --output text)
  if [[ "$status" != ACTIVE ]]; then
    aws_w ecs create-cluster --cluster-name "$CLUSTER" --tags "$(tags_json_ecs)" >/dev/null
  fi
}

register_task_def() {
  log "Registrando task definition $FAMILY"
  local def
  def=$(jq -n \
    --arg family "$FAMILY" --arg image "$IMAGE_URI" --arg exec "$EXEC_ROLE_ARN" \
    --arg cpu "$TASK_CPU" --arg mem "$TASK_MEMORY" --argjson port "$API_PORT" \
    --arg dbhost "$DB_HOST" --arg dbname "$DB_NAME" --arg dbuser "$DB_USER" \
    --arg cors "$SITE_URL" --arg version "$IMAGE_TAG" --arg logs "$LOG_GROUP" --arg region "$REGION" \
    --arg pw "arn:aws:ssm:${REGION}:${ACCOUNT}:parameter${PARAM_PREFIX}/db-password" \
    --arg jwt "arn:aws:ssm:${REGION}:${ACCOUNT}:parameter${PARAM_PREFIX}/jwt-secret" \
    --argjson tags "$(tags_json_ecs)" '{
      family: $family, networkMode: "awsvpc", requiresCompatibilities: ["FARGATE"],
      cpu: $cpu, memory: $mem, executionRoleArn: $exec,
      runtimePlatform: { operatingSystemFamily: "LINUX", cpuArchitecture: "X86_64" },
      tags: $tags,
      containerDefinitions: [{
        name: "api", image: $image, essential: true,
        portMappings: [{ containerPort: $port, protocol: "tcp" }],
        environment: [
          { name: "NODE_ENV", value: "production" },
          { name: "PORT", value: ($port | tostring) },
          { name: "PGHOST", value: $dbhost }, { name: "PGPORT", value: "5432" },
          { name: "PGDATABASE", value: $dbname }, { name: "PGUSER", value: $dbuser },
          { name: "DB_SSL", value: "true" },
          { name: "CORS_ORIGIN", value: $cors },
          { name: "APP_VERSION", value: $version }
        ],
        secrets: [
          { name: "PGPASSWORD", valueFrom: $pw },
          { name: "JWT_SECRET", valueFrom: $jwt }
        ],
        healthCheck: {
          command: ["CMD-SHELL", "wget -qO- http://127.0.0.1:\($port)/api/health >/dev/null || exit 1"],
          interval: 15, timeout: 5, retries: 3, startPeriod: 15
        },
        logConfiguration: { logDriver: "awslogs", options: {
          "awslogs-group": $logs, "awslogs-region": $region, "awslogs-stream-prefix": "ecs" } }
      }]
    }')
  TASK_DEF_ARN=$(aws_w ecs register-task-definition --cli-input-json "$def" \
    --query taskDefinition.taskDefinitionArn --output text)
  log "Task definition: $TASK_DEF_ARN"
}

network_config() {
  printf 'awsvpcConfiguration={subnets=[%s],securityGroups=[%s],assignPublicIp=ENABLED}' "$PUBLIC_SUBNET" "$SG_API"
}

run_migration() {
  log "Executando migrations em task única"
  local task_arn exit_code task_id
  task_arn=$(aws_w ecs run-task --cluster "$CLUSTER" --task-definition "$TASK_DEF_ARN" --launch-type FARGATE \
    --network-configuration "$(network_config)" --started-by deploy-migrate --propagate-tags TASK_DEFINITION \
    --overrides '{"containerOverrides":[{"name":"api","command":["node","src/migrate.js"]}]}' \
    --query 'tasks[0].taskArn' --output text)
  [[ "$DRY_RUN" == true ]] && return 0
  [[ -n "$task_arn" && "$task_arn" != None ]] || die "Não foi possível iniciar a task de migration"
  aws_wait ecs wait tasks-stopped --cluster "$CLUSTER" --tasks "$task_arn"
  exit_code=$(aws_r ecs describe-tasks --cluster "$CLUSTER" --tasks "$task_arn" \
    --query 'tasks[0].containers[0].exitCode' --output text)
  task_id="${task_arn##*/}"
  if [[ "$exit_code" != 0 ]]; then
    warn "Logs da migration:"
    aws_r logs get-log-events --log-group-name "$LOG_GROUP" --log-stream-name "ecs/api/$task_id" \
      --query 'events[].message' --output text >&2 || true
    aws_r ecs describe-tasks --cluster "$CLUSTER" --tasks "$task_arn" \
      --query 'tasks[0].[stoppedReason,containers[0].reason]' --output text >&2 || true
    die "Migration falhou (exit code: $exit_code). Deploy interrompido; a versão anterior continua no ar."
  fi
  log "Migrations aplicadas com sucesso"
}

deploy_service() {
  local status
  status=$(aws_r ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
    --query 'services[0].status' --output text)
  # Uma task só: aceita breve indisponibilidade na troca (ADR 0004).
  local deploy_cfg='deploymentCircuitBreaker={enable=true,rollback=true},minimumHealthyPercent=0,maximumPercent=100'
  if [[ "$status" == ACTIVE ]]; then
    log "Atualizando serviço $SERVICE"
    aws_w ecs update-service --cluster "$CLUSTER" --service "$SERVICE" --task-definition "$TASK_DEF_ARN" \
      --deployment-configuration "$deploy_cfg" --network-configuration "$(network_config)" >/dev/null
  else
    log "Criando serviço $SERVICE"
    aws_w ecs create-service --cluster "$CLUSTER" --service-name "$SERVICE" --task-definition "$TASK_DEF_ARN" \
      --desired-count 1 --launch-type FARGATE --network-configuration "$(network_config)" \
      --deployment-configuration "$deploy_cfg" --propagate-tags SERVICE --enable-ecs-managed-tags \
      --tags "$(tags_json_ecs)" >/dev/null
  fi
  wait_rollout
}

# `ecs wait services-stable` pode retornar antes do fim do rollout: acompanha o
# rolloutState da deployment PRIMARY e confere se ela usa a task definition nova.
wait_rollout() {
  [[ "$DRY_RUN" == true ]] && return 0
  local start=$SECONDS primary state td
  while ((SECONDS - start < ROLLOUT_TIMEOUT)); do
    primary=$(aws_r ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
      --query "services[0].deployments[?status=='PRIMARY'] | [0].[rolloutState,taskDefinition]" --output text)
    read -r state td <<<"$primary"
    if [[ "$td" != "$TASK_DEF_ARN" ]]; then
      die "Rollback do circuit breaker: a deployment primária usa $td, não $TASK_DEF_ARN. Veja os logs em $LOG_GROUP."
    fi
    case "$state" in
      COMPLETED) log "Rollout concluído"; return 0 ;;
      FAILED) die "Rollout FAILED para $TASK_DEF_ARN. Veja 'aws ecs describe-services' e os logs em $LOG_GROUP." ;;
    esac
    sleep 10
  done
  die "Tempo esgotado aguardando o rollout ($ROLLOUT_TIMEOUT s)"
}

discover_api_ip() {
  if [[ "$DRY_RUN" == true ]]; then
    API_IP=203.0.113.10
    return 0
  fi
  local tasks eni
  tasks=$(aws_r ecs list-tasks --cluster "$CLUSTER" --service-name "$SERVICE" --desired-status RUNNING \
    --query taskArns --output json | jq -r '.[]')
  [[ -n "$tasks" ]] || die "Nenhuma task em execução no serviço"
  # shellcheck disable=SC2086 # lista de ARNs intencionalmente separada por espaço
  eni=$(aws_r ecs describe-tasks --cluster "$CLUSTER" --tasks $tasks --output json |
    jq -r --arg td "$TASK_DEF_ARN" '[.tasks[] | select(.taskDefinitionArn == $td and .lastStatus == "RUNNING")][0]
      .attachments[0].details[] | select(.name == "networkInterfaceId") | .value')
  [[ -n "$eni" ]] || die "Task da revisão nova não encontrada em RUNNING"
  API_IP=$(aws_r ec2 describe-network-interfaces --network-interface-ids "$eni" \
    --query 'NetworkInterfaces[0].Association.PublicIp' --output text)
  [[ "$API_IP" =~ ^[0-9.]+$ ]] || die "A task não recebeu IPv4 público"
}

# ---- Publicação do frontend e verificação --------------------------------------------------
publish_frontend() {
  API_URL="http://${API_IP}:${API_PORT}"
  log "Publicando frontend em $SITE_URL (API: $API_URL)"
  local dist
  dist=$(mktemp -d)
  "$SCRIPT_DIR/build-frontend.sh" "$dist" "$API_URL" "$IMAGE_TAG" >&2
  if [[ "$DRY_RUN" == true ]]; then
    printf '\033[0;36m[dry-run]\033[0m aws s3 sync %s s3://%s --delete --cache-control no-cache\n' "$dist" "$BUCKET" >&2
  else
    # Sem CDN: no-cache faz o navegador revalidar (ETag) e ver a versão nova na hora.
    aws --region "$REGION" ${PROFILE:+--profile "$PROFILE"} s3 sync "$dist" "s3://$BUCKET" \
      --delete --cache-control no-cache --only-show-errors
  fi
  rm -rf "$dist"
}

smoke_test() {
  [[ "$DRY_RUN" == true ]] && { log "dry-run: verificação funcional omitida"; return 0; }
  log "Verificação funcional pós-deploy"
  local health cfg email reg token me cors
  health=$(curl -fsS --retry 10 --retry-all-errors --retry-delay 3 "$API_URL/api/health") ||
    die "Health check da API falhou em $API_URL"
  [[ "$(jq -r .version <<<"$health")" == "$IMAGE_TAG" ]] || die "API responde versão diferente: $health"

  cfg=$(curl -fsS --retry 5 --retry-all-errors --retry-delay 2 "$SITE_URL/config.js") || die "Site não publicou config.js"
  grep -qF "$API_URL" <<<"$cfg" || die "config.js do site não aponta para $API_URL"
  curl -fsS "$SITE_URL/" | grep -q 'config.js' || die "index.html do site não carregou"

  cors=$(curl -fsS -o /dev/null -D - -X OPTIONS -H "Origin: $SITE_URL" \
    -H 'Access-Control-Request-Method: POST' "$API_URL/api/register" | tr -d '\r' |
    awk -F': ' 'tolower($1)=="access-control-allow-origin"{print $2}')
  [[ "$cors" == "$SITE_URL" ]] || die "CORS não libera a origem do site (recebido: '${cors}')"

  # Registro sintético: comprova escrita e leitura no RDS pela API publicada.
  email="smoke+$(date +%s)@example.com"
  reg=$(curl -fsS -X POST -H 'Content-Type: application/json' -H "Origin: $SITE_URL" \
    -d "{\"name\":\"Smoke test\",\"email\":\"$email\",\"password\":\"smoke-$RANDOM-ok\"}" "$API_URL/api/register") ||
    die "Cadastro sintético falhou"
  token=$(jq -r .token <<<"$reg")
  me=$(curl -fsS -H "Authorization: Bearer $token" "$API_URL/api/me") || die "Consulta /api/me falhou"
  [[ "$(jq -r .user.email <<<"$me")" == "$email" ]] || die "Usuário sintético não foi persistido"
  log "Verificação OK: health, site, CORS, cadastro e consulta no banco"
}

# ---- Execução ------------------------------------------------------------------------------
ensure_network
ensure_security_groups
ensure_ecr
push_image
ensure_secrets
ensure_logs
ensure_exec_role
ensure_bucket
ensure_db
ensure_cluster
register_task_def
run_migration
deploy_service
discover_api_ip
publish_frontend
smoke_test
# Não reativa um ambiente que começou a ser destruído durante este deploy.
[[ "$(get_state)" != destroying ]] || die "Destruição iniciada durante o deploy; estado não foi reativado."
set_state active

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'site_url=%s\napi_url=%s\n' "$SITE_URL" "$API_URL" >>"$GITHUB_OUTPUT"
fi
summary "### Deploy do ambiente \`$ENV_NAME\`" "" \
  "| Item | Valor |" "|---|---|" \
  "| Commit / imagem | \`$IMAGE_TAG\` |" \
  "| Site | $SITE_URL |" \
  "| API | $API_URL |" \
  "| Task definition | \`${TASK_DEF_ARN##*/}\` |" \
  "| Verificação funcional | $([[ "$DRY_RUN" == true ]] && echo 'omitida (dry-run)' || echo 'OK') |"

log "Pronto. Site: $SITE_URL"
log "API: $API_URL (HTTP, dados sintéticos; o IP muda a cada deploy)"
