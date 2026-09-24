#!/usr/bin/env bash
# Prepara a integração GitHub Actions -> AWS por OIDC (executar uma vez, localmente).
#
# Uso:
#   scripts/bootstrap-github-oidc.sh --repo OWNER/REPO --env NOME --region REGIAO --account CONTA [opções]
#
# Opções:
#   --profile PERFIL       Perfil local da AWS CLI
#   --gh-environment NOME  Environment do GitHub usado pelo job de deploy (padrão: lab)
#   --role-name NOME       Role assumida pelo workflow (padrão: github-actions-workshop)
#   --policy-arn ARN       Política anexada à role (padrão: AdministratorAccess, ver ADR 0007)
#   --dry-run              Mostra o que seria feito
#
# O que faz (idempotente):
#   1. Reutiliza ou cria o provedor OIDC token.actions.githubusercontent.com.
#   2. Cria/atualiza a role com trust restrita ao environment do repositório,
#      lendo o formato real do subject (imutável ou não) na API do GitHub.
#   3. Cria o environment no GitHub, restrito à branch main, com as variáveis
#      AWS_ROLE_ARN, AWS_REGION, AWS_ACCOUNT_ID e LAB_ENV.
# Estes recursos são compartilhados: scripts/destroy.sh não os remove.
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

GH_REPO='' ENV_NAME='' ACCOUNT='' GH_ENV=lab ROLE_NAME=github-actions-workshop
POLICY_ARN=arn:aws:iam::aws:policy/AdministratorAccess
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) GH_REPO="${2:-}"; shift 2 ;;
    --env) ENV_NAME="${2:-}"; shift 2 ;;
    --region) REGION="${2:-}"; shift 2 ;;
    --account) ACCOUNT="${2:-}"; shift 2 ;;
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --gh-environment) GH_ENV="${2:-}"; shift 2 ;;
    --role-name) ROLE_NAME="${2:-}"; shift 2 ;;
    --policy-arn) POLICY_ARN="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h | --help) usage ;;
    *) echo "Argumento desconhecido: $1" >&2; usage ;;
  esac
done

[[ -n "$GH_REPO" && -n "$ENV_NAME" && -n "$REGION" && -n "$ACCOUNT" ]] || usage
[[ "$GH_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "Repositório inválido: $GH_REPO"
validate_env_name "$ENV_NAME"
validate_region "$REGION"
validate_account "$ACCOUNT"
need aws jq gh
OWNER="${USER:-unknown}"

check_identity "$ACCOUNT"
gh auth status >/dev/null 2>&1 || die "GitHub CLI não autenticado (gh auth login)"

# 1. Formato real do subject: repositórios com subject imutável usam owner@id/repo@id
SUB_PREFIX=$(gh api "repos/$GH_REPO/actions/oidc/customization/sub" --jq '.sub_claim_prefix // empty' 2>/dev/null || true)
if [[ -z "$SUB_PREFIX" ]]; then
  SUB_PREFIX="repo:$GH_REPO"
fi
log "Subject OIDC do repositório: ${SUB_PREFIX}:environment:${GH_ENV}"

# 2. Provedor OIDC (reutiliza se existir)
PROVIDER_ARN="arn:aws:iam::${ACCOUNT}:oidc-provider/token.actions.githubusercontent.com"
if [[ -z "$(aws_r iam get-open-id-connect-provider --open-id-connect-provider-arn "$PROVIDER_ARN" --query Url --output text)" ]]; then
  log "Criando provedor OIDC do GitHub"
  aws_w iam create-open-id-connect-provider --url https://token.actions.githubusercontent.com \
    --client-id-list sts.amazonaws.com >/dev/null
else
  log "Provedor OIDC já existe; reutilizando"
fi

# 3. Role do workflow
TRUST=$(policy_github_trust "$ACCOUNT" "$SUB_PREFIX" "$GH_ENV")
if [[ -z "$(aws_r iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text)" ]]; then
  log "Criando role $ROLE_NAME"
  aws_w iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "$TRUST" \
    --description "GitHub Actions OIDC - $GH_REPO ($GH_ENV)" --tags "$(tags_json)" >/dev/null
else
  log "Atualizando trust da role $ROLE_NAME"
  aws_w iam update-assume-role-policy --role-name "$ROLE_NAME" --policy-document "$TRUST" >/dev/null
  aws_w iam update-role --role-name "$ROLE_NAME" --description "GitHub Actions OIDC - $GH_REPO ($GH_ENV)" >/dev/null
fi
aws_w iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN" >/dev/null
ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/${ROLE_NAME}"

# 4. Environment e variáveis no GitHub (não são segredos: o ARN não concede acesso sozinho)
gh_w() {
  if [[ "$DRY_RUN" == true ]]; then
    printf '\033[0;36m[dry-run]\033[0m gh %s\n' "$*" >&2
  else
    gh "$@"
  fi
}
log "Configurando environment '$GH_ENV' no GitHub (somente branch main)"
gh_w api -X PUT "repos/$GH_REPO/environments/$GH_ENV" --input - >/dev/null <<<'{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}'
if [[ "$DRY_RUN" == true ]] || ! gh api "repos/$GH_REPO/environments/$GH_ENV/deployment-branch-policies" \
  --jq '.branch_policies[].name' 2>/dev/null | grep -qx main; then
  gh_w api -X POST "repos/$GH_REPO/environments/$GH_ENV/deployment-branch-policies" -f name=main -f type=branch >/dev/null
fi
gh_w variable set AWS_ROLE_ARN --repo "$GH_REPO" --env "$GH_ENV" --body "$ROLE_ARN"
gh_w variable set AWS_REGION --repo "$GH_REPO" --env "$GH_ENV" --body "$REGION"
gh_w variable set AWS_ACCOUNT_ID --repo "$GH_REPO" --env "$GH_ENV" --body "$ACCOUNT"
gh_w variable set LAB_ENV --repo "$GH_REPO" --env "$GH_ENV" --body "$ENV_NAME"

log "Pronto: $ROLE_ARN aceita somente ${SUB_PREFIX}:environment:${GH_ENV}"
log "A propagação da trust no IAM pode levar alguns segundos."
