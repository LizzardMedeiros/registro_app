# shellcheck shell=bash
# Funções compartilhadas por deploy.sh, destroy.sh e bootstrap-github-oidc.sh.
# Não execute diretamente: use `source`.

PROJECT=registro-app
DRY_RUN=${DRY_RUN:-false}
PROFILE=${PROFILE:-}
REGION=${REGION:-}

log() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[aviso]\033[0m %s\n' "$*" >&2; }
die() {
  printf '\033[1;31m[erro]\033[0m %s\n' "$*" >&2
  exit 1
}

need() {
  local dep
  for dep in "$@"; do
    command -v "$dep" >/dev/null || die "Dependência ausente: $dep"
  done
}

# Ambiente: minúsculas, dígitos e hífen; vira parte de nomes de bucket e RDS.
validate_env_name() {
  [[ "$1" =~ ^[a-z][a-z0-9-]{2,20}$ && "$1" != *- ]] ||
    die "Ambiente inválido '$1': use 3-21 caracteres [a-z0-9-], começando por letra"
}

validate_region() {
  [[ "$1" =~ ^[a-z]{2}(-[a-z]+)+-[0-9]$ ]] || die "Região inválida: '$1'"
}

validate_account() {
  [[ "$1" =~ ^[0-9]{12}$ ]] || die "Conta AWS inválida: '$1' (esperado 12 dígitos)"
}

# Chamada de leitura. Imprime o resultado; em caso de "não encontrado" imprime
# vazio. Outros erros abortam, exceto em dry-run (conta pode estar sem acesso).
aws_r() {
  local out err rc
  err=$(mktemp)
  set +e
  out=$(aws --region "$REGION" ${PROFILE:+--profile "$PROFILE"} --output json "$@" 2>"$err")
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    if grep -qiE 'NotFound|NoSuch|does not exist|not found|cannot be found|InvalidParameterValue.*not exist' "$err"; then
      rm -f "$err"
      return 0
    fi
    if [[ "$DRY_RUN" == true ]]; then
      warn "leitura falhou em dry-run (tratada como vazia): aws $1 $2: $(head -c 200 "$err")"
      rm -f "$err"
      return 0
    fi
    cat "$err" >&2
    rm -f "$err"
    die "Falha em: aws $*"
  fi
  rm -f "$err"
  printf '%s' "$out"
}

# Oculta valores sensíveis ao exibir um comando.
mask_args() {
  local out=() hide=false a
  for a in "$@"; do
    if [[ "$hide" == true ]]; then
      out+=('***')
      hide=false
      continue
    fi
    [[ "$a" == --value || "$a" == --master-user-password ]] && hide=true
    out+=("$a")
  done
  printf '%s' "${out[*]}"
}

# Chamada que altera a conta. Em dry-run só mostra o comando e imprime DRYRUN.
aws_w() {
  if [[ "$DRY_RUN" == true ]]; then
    printf '\033[0;36m[dry-run]\033[0m aws %s\n' "$(mask_args "$@")" >&2
    printf 'DRYRUN'
    return 0
  fi
  aws --region "$REGION" ${PROFILE:+--profile "$PROFILE"} --output json "$@"
}

# Espera (waiter ou loop). Ignorada em dry-run.
aws_wait() {
  if [[ "$DRY_RUN" == true ]]; then
    printf '\033[0;36m[dry-run]\033[0m aws %s\n' "$*" >&2
    return 0
  fi
  aws --region "$REGION" ${PROFILE:+--profile "$PROFILE"} "$@"
}

# Confere se as credenciais pertencem à conta esperada (perfil local ou OIDC).
check_identity() {
  local expected="$1" actual arn
  actual=$(aws --region "$REGION" ${PROFILE:+--profile "$PROFILE"} sts get-caller-identity \
    --query Account --output text) || die "Sem credenciais AWS válidas (rode 'aws login' ou confira o OIDC)"
  [[ "$actual" == "$expected" ]] || die "Credencial da conta $actual, mas o ambiente é da conta $expected"
  arn=$(aws --region "$REGION" ${PROFILE:+--profile "$PROFILE"} sts get-caller-identity --query Arn --output text)
  [[ "$arn" == *":root" ]] && warn "Credencial root em uso (aceito para este laboratório, ver ADR 0002)"
  log "Conta $actual confirmada ($arn)"
}

# Tags padrão em formato "Key=..,Value=.." (EC2, RDS, ECR) e JSON de objetos.
tags_kv() {
  printf 'Key=Project,Value=%s Key=Environment,Value=%s Key=Owner,Value=%s Key=ManagedBy,Value=scripts' \
    "$PROJECT" "$ENV_NAME" "$OWNER"
}
tags_json() {
  jq -cn --arg p "$PROJECT" --arg e "$ENV_NAME" --arg o "$OWNER" \
    '[{Key:"Project",Value:$p},{Key:"Environment",Value:$e},{Key:"Owner",Value:$o},{Key:"ManagedBy",Value:"scripts"}]'
}
# ECS usa key/value minúsculos
tags_json_ecs() { tags_json | jq -c 'map({key:.Key, value:.Value})'; }
# tag-specifications do EC2 com Name
ec2_tagspec() {
  local type="$1" name="$2"
  printf 'ResourceType=%s,Tags=[{Key=Name,Value=%s},{Key=Project,Value=%s},{Key=Environment,Value=%s},{Key=Owner,Value=%s},{Key=ManagedBy,Value=scripts}]' \
    "$type" "$name" "$PROJECT" "$ENV_NAME" "$OWNER"
}

# Estado do laboratório no SSM: active | provisioning | destroying | (vazio)
state_param() { printf '/registro/%s/state' "$ENV_NAME"; }
get_state() {
  aws_r ssm get-parameter --name "$(state_param)" --query Parameter.Value --output text
}
set_state() {
  aws_w ssm put-parameter --name "$(state_param)" --type String --overwrite --value "$1" >/dev/null
}

# Resumo no GitHub Actions (no-op fora do CI)
summary() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n' "$*" >>"$GITHUB_STEP_SUMMARY"
  fi
}
