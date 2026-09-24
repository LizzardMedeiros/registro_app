#!/usr/bin/env bash
# Gera o build estático do frontend com a configuração pública do ambiente.
#
# Uso:
#   scripts/build-frontend.sh <diretório-saída> <url-da-api> <versão>
#
# <url-da-api> vazio mantém chamadas na mesma origem (proxy do nginx local).
# O config.js gerado é público: nunca passe segredos para este script.
set -euo pipefail

if [[ $# -ne 3 ]]; then
  sed -n '2,8p' "$0" >&2
  exit 2
fi

OUT="$1"
API_URL="$2"
VERSION="$3"
SRC="$(cd "$(dirname "$0")/../frontend" && pwd)"

command -v jq >/dev/null || { echo "Dependência ausente: jq" >&2; exit 1; }
if [[ -n "$API_URL" && ! "$API_URL" =~ ^https?://[^[:space:]]+$ ]]; then
  echo "URL da API inválida: $API_URL" >&2
  exit 2
fi

rm -rf "$OUT"
mkdir -p "$OUT"
cp "$SRC/index.html" "$SRC/app.js" "$SRC/style.css" "$OUT/"

# jq garante escape correto dos valores no JavaScript gerado
CONFIG_JSON=$(jq -n --arg api "$API_URL" --arg version "$VERSION" '{apiBaseUrl: $api, version: $version}')
printf '// Gerado por scripts/build-frontend.sh. Público: sem segredos.\nwindow.APP_CONFIG = %s;\n' \
  "$CONFIG_JSON" > "$OUT/config.js"

echo "Frontend gerado em $OUT (api='${API_URL:-mesma origem}', versão=$VERSION)"
