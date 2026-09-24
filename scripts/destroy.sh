#!/usr/bin/env bash
# Remove todos os recursos exclusivos de um ambiente do laboratório, INCLUINDO
# os dados de teste do banco (sem snapshot final e sem backups retidos).
#
# Uso:
#   scripts/destroy.sh --env NOME --region REGIAO --account CONTA [opções]
#
# Opções:
#   --profile PERFIL  Perfil local da AWS CLI
#   --yes             Não interativo: use somente após a confirmação explícita
#                     do responsável (ex.: o agente, depois do "sim" na conversa)
#   --dry-run         Mostra o que seria removido, sem alterar a conta
#
# Sem --yes, o script pede que você digite o nome do ambiente para confirmar.
# Preserva recursos compartilhados: provedor OIDC do GitHub e a role de deploy
# do GitHub Actions (criados pelo bootstrap, ver ADR 0007).
# shellcheck source-path=SCRIPTDIR
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
  sed -n '2,17p' "$0" >&2
  exit 2
}

ENV_NAME='' ACCOUNT='' YES=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) ENV_NAME="${2:-}"; shift 2 ;;
    --region) REGION="${2:-}"; shift 2 ;;
    --account) ACCOUNT="${2:-}"; shift 2 ;;
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --yes) YES=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h | --help) usage ;;
    *) echo "Argumento desconhecido: $1" >&2; usage ;;
  esac
done

[[ -n "$ENV_NAME" && -n "$REGION" && -n "$ACCOUNT" ]] || usage
validate_env_name "$ENV_NAME"
validate_region "$REGION"
validate_account "$ACCOUNT"
need aws jq

PREFIX="registro-${ENV_NAME}"
DB_ID="${PREFIX}-db"
CLUSTER="${PREFIX}"
SERVICE="${PREFIX}-api"
FAMILY="${PREFIX}-api"
REPO="${PREFIX}-api"
LOG_GROUP="/ecs/${PREFIX}"
EXEC_ROLE="${PREFIX}-ecs-exec"
BUCKET="${PREFIX}-${ACCOUNT}-site"
PARAM_PREFIX="/registro/${ENV_NAME}"
OWNER="${USER:-unknown}"

check_identity "$ACCOUNT"

if [[ "$YES" != true && "$DRY_RUN" != true ]]; then
  [[ -t 0 ]] || die "Sem terminal para confirmar. Rode com --yes somente após confirmação explícita."
  printf 'Isto remove o ambiente %s na conta %s, INCLUINDO o banco e os dados de teste.\n' "$ENV_NAME" "$ACCOUNT" >&2
  read -r -p "Digite o nome do ambiente para confirmar: " answer
  [[ "$answer" == "$ENV_NAME" ]] || die "Confirmação não confere. Nada foi removido."
fi

FAILURES=()
try() { # descrição comando... (registra falha sem abortar a limpeza)
  local desc="$1" rc
  shift
  # Subshell fora de condicional: mantém o `set -e` ativo dentro da etapa.
  set +e
  (
    set -e
    "$@"
  )
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    warn "Falhou: $desc"
    FAILURES+=("$desc")
  fi
}

log "Destruindo ambiente $ENV_NAME (dry-run=$DRY_RUN)"
# Marca o estado primeiro: pushes na main passam a ignorar o deploy.
[[ -z "$(get_state)" ]] || set_state destroying

# ---- ECS ------------------------------------------------------------------------
destroy_ecs() {
  local status tasks arns
  status=$(aws_r ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
    --query 'services[0].status' --output text)
  if [[ "$status" == ACTIVE || "$status" == DRAINING ]]; then
    log "Removendo serviço $SERVICE"
    aws_w ecs update-service --cluster "$CLUSTER" --service "$SERVICE" --desired-count 0 >/dev/null
    aws_w ecs delete-service --cluster "$CLUSTER" --service "$SERVICE" --force >/dev/null
    aws_wait ecs wait services-inactive --cluster "$CLUSTER" --services "$SERVICE"
  fi

  tasks=$(aws_r ecs list-tasks --cluster "$CLUSTER" --query taskArns --output json | jq -r '.[]?')
  if [[ -n "$tasks" ]]; then
    log "Parando tasks restantes"
    local t
    for t in $tasks; do aws_w ecs stop-task --cluster "$CLUSTER" --task "$t" >/dev/null; done
    # shellcheck disable=SC2086
    aws_wait ecs wait tasks-stopped --cluster "$CLUSTER" --tasks $tasks
  fi

  arns=$(aws_r ecs list-task-definitions --family-prefix "$FAMILY" --status ACTIVE \
    --query taskDefinitionArns --output json | jq -r '.[]?')
  local a
  for a in $arns; do aws_w ecs deregister-task-definition --task-definition "$a" >/dev/null; done
  arns=$(aws_r ecs list-task-definitions --family-prefix "$FAMILY" --status INACTIVE \
    --query taskDefinitionArns --output json | jq -r '.[]?')
  if [[ -n "$arns" ]]; then
    # delete-task-definitions aceita até 10 por chamada
    # shellcheck disable=SC2086
    printf '%s\n' $arns | xargs -n 10 echo | while read -r batch; do
      # shellcheck disable=SC2086
      aws_w ecs delete-task-definitions --task-definitions $batch >/dev/null
    done
  fi

  status=$(aws_r ecs describe-clusters --clusters "$CLUSTER" --query 'clusters[0].status' --output text)
  if [[ "$status" == ACTIVE ]]; then
    log "Removendo cluster $CLUSTER"
    aws_w ecs delete-cluster --cluster "$CLUSTER" >/dev/null
  fi
}

# ---- RDS ------------------------------------------------------------------------
destroy_rds() {
  local status snaps s
  status=$(aws_r rds describe-db-instances --db-instance-identifier "$DB_ID" \
    --query 'DBInstances[0].DBInstanceStatus' --output text)
  if [[ -n "$status" && "$status" != deleting ]]; then
    log "Removendo banco $DB_ID sem snapshot final e sem backups retidos"
    aws_w rds delete-db-instance --db-instance-identifier "$DB_ID" \
      --skip-final-snapshot --delete-automated-backups >/dev/null
  fi
  if [[ -n "$status" ]]; then
    log "Aguardando exclusão do banco (alguns minutos)"
    aws_wait rds wait db-instance-deleted --db-instance-identifier "$DB_ID"
  fi
  # Snapshots manuais deste banco (dados sintéticos do mesmo ambiente)
  snaps=$(aws_r rds describe-db-snapshots --db-instance-identifier "$DB_ID" --snapshot-type manual \
    --query 'DBSnapshots[].DBSnapshotIdentifier' --output text)
  for s in $snaps; do
    [[ "$s" == None ]] && continue
    aws_w rds delete-db-snapshot --db-snapshot-identifier "$s" >/dev/null
  done
  if [[ -n "$(aws_r rds describe-db-subnet-groups --db-subnet-group-name "${PREFIX}-db-subnets" \
    --query 'DBSubnetGroups[0].DBSubnetGroupName' --output text)" ]]; then
    aws_w rds delete-db-subnet-group --db-subnet-group-name "${PREFIX}-db-subnets" >/dev/null
  fi
}

# ---- ECR, S3, logs, IAM, SSM -------------------------------------------------------
destroy_ecr() {
  if [[ -n "$(aws_r ecr describe-repositories --repository-names "$REPO" \
    --query 'repositories[0].repositoryName' --output text)" ]]; then
    log "Removendo repositório ECR $REPO e imagens"
    aws_w ecr delete-repository --repository-name "$REPO" --force >/dev/null
  fi
}

destroy_bucket() {
  [[ -n "$(aws_r s3api head-bucket --bucket "$BUCKET" --query BucketRegion --output text)" ]] || return 0
  log "Esvaziando e removendo bucket $BUCKET (objetos e versões)"
  local batch
  while :; do
    batch=$(aws_r s3api list-object-versions --bucket "$BUCKET" --max-items 1000 --output json |
      jq -c 'select(.) | {Objects: ([(.Versions // [])[], (.DeleteMarkers // [])[]] | map({Key, VersionId})), Quiet: true}
        | select(.Objects | length > 0)')
    [[ "$DRY_RUN" == true || -z "$batch" ]] && break
    aws_w s3api delete-objects --bucket "$BUCKET" --delete "$batch" >/dev/null
  done
  aws_w s3api delete-bucket --bucket "$BUCKET" >/dev/null
}

destroy_logs() {
  if [[ -n "$(aws_r logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" \
    --query "logGroups[?logGroupName=='$LOG_GROUP'] | [0].logGroupName" --output text | sed 's/^None$//')" ]]; then
    aws_w logs delete-log-group --log-group-name "$LOG_GROUP" >/dev/null
  fi
}

destroy_iam() {
  [[ -n "$(aws_r iam get-role --role-name "$EXEC_ROLE" --query Role.Arn --output text)" ]] || return 0
  log "Removendo role $EXEC_ROLE"
  local p
  for p in $(aws_r iam list-role-policies --role-name "$EXEC_ROLE" --query PolicyNames --output text); do
    aws_w iam delete-role-policy --role-name "$EXEC_ROLE" --policy-name "$p" >/dev/null
  done
  for p in $(aws_r iam list-attached-role-policies --role-name "$EXEC_ROLE" \
    --query 'AttachedPolicies[].PolicyArn' --output text); do
    aws_w iam detach-role-policy --role-name "$EXEC_ROLE" --policy-arn "$p" >/dev/null
  done
  aws_w iam delete-role --role-name "$EXEC_ROLE" >/dev/null
}

destroy_secrets() {
  local names
  names=$(aws_r ssm describe-parameters --parameter-filters "Key=Name,Option=BeginsWith,Values=$PARAM_PREFIX/" \
    --query 'Parameters[].Name' --output text)
  # O parâmetro de estado sai por último, em destroy_state
  names=$(tr '\t' '\n' <<<"$names" | grep -vx "$(state_param)" | grep -v '^None$' || true)
  [[ -z "$names" ]] && return 0
  # shellcheck disable=SC2086
  aws_w ssm delete-parameters --names $names >/dev/null
}

# ---- Rede --------------------------------------------------------------------------
destroy_network() {
  local vpc enis start id
  vpc=$(aws_r ec2 describe-vpcs --filters "Name=tag:Name,Values=${PREFIX}-vpc" "Name=tag:Environment,Values=${ENV_NAME}" \
    --query 'Vpcs[0].VpcId' --output text | sed 's/^None$//')
  [[ -n "$vpc" ]] || return 0
  log "Removendo rede da VPC $vpc"

  # ENIs do Fargate e do RDS demoram alguns minutos para sumir após a exclusão.
  if [[ "$DRY_RUN" != true ]]; then
    start=$SECONDS
    while :; do
      enis=$(aws_r ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$vpc" \
        --query 'NetworkInterfaces[].NetworkInterfaceId' --output text)
      [[ -z "$enis" ]] && break
      ((SECONDS - start > 900)) && { warn "ENIs ainda presentes: $enis"; break; }
      sleep 15
    done
  fi

  for id in $(aws_r ec2 describe-security-groups --filters "Name=vpc-id,Values=$vpc" \
    --query "SecurityGroups[?GroupName!='default'].GroupId" --output text); do
    # remove referências cruzadas antes de apagar os grupos
    local perms
    perms=$(aws_r ec2 describe-security-groups --group-ids "$id" --query 'SecurityGroups[0].IpPermissions' --output json)
    if [[ -n "$perms" && "$perms" != "[]" ]]; then
      aws_w ec2 revoke-security-group-ingress --group-id "$id" --ip-permissions "$perms" >/dev/null
    fi
  done
  for id in $(aws_r ec2 describe-security-groups --filters "Name=vpc-id,Values=$vpc" \
    --query "SecurityGroups[?GroupName!='default'].GroupId" --output text); do
    aws_w ec2 delete-security-group --group-id "$id" >/dev/null
  done

  for id in $(aws_r ec2 describe-route-tables --filters "Name=vpc-id,Values=$vpc" \
    --query 'RouteTables[?!(Associations[?Main])].RouteTableId' --output text); do
    local assoc
    for assoc in $(aws_r ec2 describe-route-tables --route-table-ids "$id" \
      --query 'RouteTables[0].Associations[].RouteTableAssociationId' --output text); do
      aws_w ec2 disassociate-route-table --association-id "$assoc" >/dev/null
    done
    aws_w ec2 delete-route-table --route-table-id "$id" >/dev/null
  done

  for id in $(aws_r ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc" --query 'Subnets[].SubnetId' --output text); do
    aws_w ec2 delete-subnet --subnet-id "$id" >/dev/null
  done

  for id in $(aws_r ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$vpc" \
    --query 'InternetGateways[].InternetGatewayId' --output text); do
    aws_w ec2 detach-internet-gateway --internet-gateway-id "$id" --vpc-id "$vpc" >/dev/null
    aws_w ec2 delete-internet-gateway --internet-gateway-id "$id" >/dev/null
  done

  aws_w ec2 delete-vpc --vpc-id "$vpc" >/dev/null
}

destroy_state() {
  [[ -z "$(get_state)" ]] || aws_w ssm delete-parameter --name "$(state_param)" >/dev/null
}

# ---- Conferência de remanescentes --------------------------------------------------
check_residuals() {
  log "Conferindo recursos remanescentes"
  local left=() v
  check() { [[ -z "$2" || "$2" == None || "$2" == INACTIVE ]] || left+=("$1: $2"); }
  check "RDS" "$(aws_r rds describe-db-instances --db-instance-identifier "$DB_ID" --query 'DBInstances[0].DBInstanceStatus' --output text)"
  check "Snapshots RDS" "$(aws_r rds describe-db-snapshots --db-instance-identifier "$DB_ID" --query 'DBSnapshots[].DBSnapshotIdentifier' --output text)"
  check "Backups retidos RDS" "$(aws_r rds describe-db-instance-automated-backups --db-instance-identifier "$DB_ID" --query 'DBInstanceAutomatedBackups[].DBInstanceIdentifier' --output text)"
  check "Cluster ECS" "$(aws_r ecs describe-clusters --clusters "$CLUSTER" --query 'clusters[0].status' --output text)"
  check "Task definitions" "$(aws_r ecs list-task-definitions --family-prefix "$FAMILY" --query 'taskDefinitionArns' --output text)"
  check "ECR" "$(aws_r ecr describe-repositories --repository-names "$REPO" --query 'repositories[0].repositoryName' --output text)"
  check "Bucket" "$(aws_r s3api head-bucket --bucket "$BUCKET" --query BucketRegion --output text)"
  check "Log group" "$(aws_r logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" --query 'logGroups[].logGroupName' --output text)"
  check "Role IAM" "$(aws_r iam get-role --role-name "$EXEC_ROLE" --query Role.Arn --output text)"
  check "Parâmetros SSM" "$(aws_r ssm describe-parameters --parameter-filters "Key=Name,Option=BeginsWith,Values=$PARAM_PREFIX/" --query 'Parameters[].Name' --output text)"
  v=$(aws_r ec2 describe-vpcs --filters "Name=tag:Environment,Values=$ENV_NAME" "Name=tag:Project,Values=$PROJECT" --query 'Vpcs[].VpcId' --output text)
  check "VPC" "$v"
  check "ENIs/IPs públicos" "$(aws_r ec2 describe-network-interfaces --filters "Name=tag:Environment,Values=$ENV_NAME" --query 'NetworkInterfaces[].NetworkInterfaceId' --output text)"

  if [[ "$DRY_RUN" == true ]]; then
    log "dry-run: nada foi removido"
    return 0
  fi
  if [[ ${#left[@]} -gt 0 || ${#FAILURES[@]} -gt 0 ]]; then
    printf '  remanescente: %s\n' "${left[@]}" >&2
    [[ ${#FAILURES[@]} -eq 0 ]] || printf '  falha: %s\n' "${FAILURES[@]}" >&2
    summary "### Destruição de \`$ENV_NAME\` incompleta" "" "$(printf -- '- %s\n' "${left[@]}" "${FAILURES[@]}")"
    die "Destruição incompleta; recursos acima podem continuar gerando custo"
  fi
  summary "### Ambiente \`$ENV_NAME\` destruído" "" "Nenhum recurso remanescente encontrado. Cobranças podem aparecer no faturamento com atraso."
  log "Ambiente $ENV_NAME removido. Nenhum remanescente encontrado."
  log "Preservados (compartilhados): provedor OIDC do GitHub e role de deploy do GitHub Actions."
  log "O faturamento pode levar até 24 h para refletir; confira em Billing > Bills."
}

try "ECS" destroy_ecs
try "RDS" destroy_rds
try "ECR" destroy_ecr
try "S3" destroy_bucket
try "CloudWatch Logs" destroy_logs
try "IAM" destroy_iam
try "SSM" destroy_secrets
try "Rede" destroy_network
[[ ${#FAILURES[@]} -gt 0 ]] || try "Estado" destroy_state
check_residuals
