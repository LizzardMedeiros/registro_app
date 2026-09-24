#!/usr/bin/env bash
# Validações dos scripts shell e das políticas que eles geram (sem acesso à AWS).
#
# Uso: bash scripts/test/run.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf 'ok - %s\n' "$1"; }
ko() { FAIL=$((FAIL + 1)); printf 'not ok - %s\n' "$1"; [[ -z "${2:-}" ]] || printf '  %s\n' "$2"; }
assert() { # descrição comando...
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else ko "$desc"; fi
}
assert_fails_with() { # descrição código-esperado comando...
  local desc="$1" expected="$2" rc=0
  shift 2
  "$@" >/dev/null 2>&1 || rc=$?
  if [[ $rc -eq $expected ]]; then ok "$desc"; else ko "$desc" "exit $rc, esperado $expected"; fi
}

mapfile -t SCRIPTS < <(find scripts -name '*.sh' -type f | sort)

# --- Sintaxe, lint e permissões ---------------------------------------------------
for f in "${SCRIPTS[@]}"; do
  assert "bash -n $f" bash -n "$f"
done
if shellcheck -x "${SCRIPTS[@]}"; then ok "shellcheck em ${#SCRIPTS[@]} scripts"; else ko "shellcheck"; fi
for f in scripts/deploy.sh scripts/destroy.sh scripts/bootstrap-github-oidc.sh scripts/build-frontend.sh scripts/estimate-cost.sh; do
  assert "$f é executável e declara bash" bash -c "[[ -x '$f' ]] && head -1 '$f' | grep -qx '#!/usr/bin/env bash'"
done

# --- Políticas geradas -----------------------------------------------------------
# shellcheck source=scripts/lib/policies.sh
source scripts/lib/policies.sh

p=$(policy_site_bucket registro-lab-x-123456789012-site)
assert "bucket: JSON válido" jq -e . <<<"$p"
assert "bucket: só s3:GetObject público" jq -e '.Statement | length == 1 and .[0].Action == "s3:GetObject" and .[0].Principal == "*"' <<<"$p"
assert "bucket: restrito aos objetos do próprio bucket" jq -e '.Statement[0].Resource == "arn:aws:s3:::registro-lab-x-123456789012-site/*"' <<<"$p"
assert "bucket: sem escrita, listagem ou wildcard de ação" \
  bash -c "! jq -r '.. | .Action? // empty | if type==\"array\" then .[] else . end' <<<'$p' | grep -qE 'Put|Delete|List|\\*'"

p=$(policy_ecs_exec_trust 123456789012)
assert "exec trust: só ecs-tasks e da própria conta" \
  jq -e '.Statement[0].Principal.Service == "ecs-tasks.amazonaws.com" and .Statement[0].Condition.StringEquals["aws:SourceAccount"] == "123456789012"' <<<"$p"

p=$(policy_ecs_exec_ssm 123456789012 us-east-1 lab-x)
assert "exec ssm: somente leitura (GetParameters)" jq -e '.Statement[0].Action == ["ssm:GetParameters"]' <<<"$p"
assert "exec ssm: limitado ao prefixo do ambiente" \
  jq -e '.Statement[0].Resource == "arn:aws:ssm:us-east-1:123456789012:parameter/registro/lab-x/*"' <<<"$p"

p=$(policy_github_trust 123456789012 'repo:dono@1/repo@2' lab)
assert "github trust: audience sts.amazonaws.com" \
  jq -e '.Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:aud"] == "sts.amazonaws.com"' <<<"$p"
assert "github trust: subject exato do environment (sem curinga)" \
  jq -e '.Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == "repo:dono@1/repo@2:environment:lab" and (.Statement[0].Condition | has("StringLike") | not)' <<<"$p"
assert "github trust: provedor OIDC da própria conta" \
  jq -e '.Statement[0].Principal.Federated == "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"' <<<"$p"

# --- Mascaramento em dry-run --------------------------------------------------------
# shellcheck source=scripts/lib/common.sh
source scripts/lib/common.sh
masked=$(DRY_RUN=true aws_w rds create-db-instance --master-user-password 's3nh4' --db-name x 2>&1 >/dev/null)
assert "dry-run oculta a senha do banco" bash -c "grep -q -- '--master-user-password \*\*\*' <<<'$masked' && ! grep -q s3nh4 <<<'$masked'"
masked=$(DRY_RUN=true aws_w ssm put-parameter --name /x --value 'segredo123' 2>&1 >/dev/null)
assert "dry-run oculta o valor de parâmetros" bash -c "! grep -q segredo123 <<<'$masked'"

# --- build-frontend.sh ------------------------------------------------------------
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
scripts/build-frontend.sh "$tmp/out" 'http://203.0.113.7:3000' 'abc"123' >/dev/null
assert "build: copia os arquivos do site" test -f "$tmp/out/index.html" -a -f "$tmp/out/app.js" -a -f "$tmp/out/style.css"
# extrai o objeto JSON atribuído a window.APP_CONFIG
cfg_json=$(grep -v '^//' "$tmp/out/config.js" | sed -e 's/^window.APP_CONFIG = //' -e 's/;$//')
assert "build: config.js com URL da API e versão escapada" \
  jq -e '.apiBaseUrl == "http://203.0.113.7:3000" and .version == "abc\"123"' <<<"$cfg_json"
assert "build: config.js não contém segredos" bash -c "! grep -qiE 'secret|password|token' '$tmp/out/config.js'"
assert_fails_with "build: rejeita URL inválida" 2 scripts/build-frontend.sh "$tmp/x" 'javascript:alert(1)' v1
assert_fails_with "build: exige 3 argumentos" 2 scripts/build-frontend.sh "$tmp/x"

# --- Validação de argumentos (antes de qualquer chamada à AWS) -------------------------
assert_fails_with "deploy: sem argumentos mostra uso" 2 scripts/deploy.sh
assert_fails_with "deploy: argumento desconhecido" 2 scripts/deploy.sh --foo
assert_fails_with "deploy: ambiente inválido" 1 scripts/deploy.sh --env 'Lab_X' --region us-east-1 --account 123456789012 --image-tag abc
assert_fails_with "deploy: conta inválida" 1 scripts/deploy.sh --env lab-x --region us-east-1 --account 123 --image-tag abc
assert_fails_with "deploy: tag de imagem inválida" 1 scripts/deploy.sh --env lab-x --region us-east-1 --account 123456789012 --image-tag 'a b'
assert_fails_with "destroy: sem argumentos mostra uso" 2 scripts/destroy.sh
assert_fails_with "destroy: região inválida" 1 scripts/destroy.sh --env lab-x --region useast --account 123456789012
assert_fails_with "bootstrap: repositório inválido" 1 scripts/bootstrap-github-oidc.sh --repo invalido --env lab-x --region us-east-1 --account 123456789012

# --- Garantias estruturais -------------------------------------------------------
assert "deploy.sh nunca chama destruição" bash -c "! grep -vE '^\s*#' scripts/deploy.sh | grep -nE 'destroy\.sh|delete-db-instance|delete-vpc|delete-bucket|delete-repository'"
assert "destroy.sh preserva o provedor OIDC e a role do GitHub" bash -c "! grep -nE 'delete-open-id-connect-provider|github-actions' scripts/destroy.sh"
assert "destroy.sh exige confirmação sem --yes" grep -q 'Digite o nome do ambiente para confirmar' scripts/destroy.sh
assert "destroy.sh remove o RDS sem snapshot e sem backups" grep -q -- '--skip-final-snapshot --delete-automated-backups' scripts/destroy.sh
assert "deploy.sh cria RDS privado e sem backups" bash -c "grep -q -- '--no-publicly-accessible' scripts/deploy.sh && grep -q -- '--backup-retention-period 0' scripts/deploy.sh"
assert "nenhum script contém credenciais AWS fixas" bash -c "! grep -rnE --exclude-dir=test 'AKIA[0-9A-Z]{16}|aws_secret_access_key' scripts .github api/src frontend"

printf '\n%d ok, %d falhas\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
