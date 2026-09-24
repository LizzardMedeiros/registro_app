#!/usr/bin/env bash
# Estima o custo do ambiente do laboratório com preços vigentes da AWS Pricing API.
#
# Uso:
#   scripts/estimate-cost.sh [--hours N] [--region us-east-1] [--profile NOME]
#
# Somente leitura: não cria nem altera recursos. A Pricing API é consultada em
# us-east-1, independentemente da região do ambiente.
set -euo pipefail

HOURS=2
REGION=us-east-1
PROFILE_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hours) HOURS="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --profile) PROFILE_ARGS=(--profile "$2"); shift 2 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "Argumento desconhecido: $1" >&2; exit 2 ;;
  esac
done

for dep in aws jq awk; do
  command -v "$dep" >/dev/null || { echo "Dependência ausente: $dep" >&2; exit 1; }
done

# Parâmetros do ambiente (manter alinhados com scripts/deploy.sh)
FARGATE_VCPU=0.25
FARGATE_GB=0.5
RDS_CLASS=db.t4g.micro
RDS_STORAGE_GB=20
IMAGE_GB=0.1        # imagem node:22-alpine + deps, ~60 MB comprimida; margem
LOG_GB=0.01         # poucos acessos de teste
S3_REQUESTS_PUT=50  # uploads do site por deploy x poucos deploys
S3_REQUESTS_GET=2000
# Tasks temporárias: migration (~1 min por deploy) e sobreposição no rollout
EXTRA_TASK_HOURS=0.5

# Os usagetypes abaixo seguem a nomenclatura de us-east-1 (prefixo USE1- ou sem prefixo).
[[ "$REGION" == us-east-1 ]] || { echo "Estimativa suportada apenas para us-east-1" >&2; exit 1; }
REGION_CODE="$REGION"
HOURS_PER_MONTH=730

# price SERVICE FILTER... -> preço USD por unidade (OnDemand, primeiro tier > 0)
price() {
  local service="$1"; shift
  local filters=("Type=TERM_MATCH,Field=regionCode,Value=$REGION_CODE")
  for f in "$@"; do filters+=("Type=TERM_MATCH,Field=${f%%=*},Value=${f#*=}"); done
  aws "${PROFILE_ARGS[@]}" pricing get-products --region us-east-1 \
    --service-code "$service" --filters "${filters[@]}" --output json \
    | jq -r '[.PriceList[] | fromjson | .terms.OnDemand // {} | .[] | .priceDimensions[]
              | .pricePerUnit.USD | tonumber | select(. > 0)] | sort | last // empty'
}

require() {
  [[ -n "$2" ]] || { echo "Preço não encontrado: $1" >&2; exit 1; }
  echo "$2"
}

P_VCPU=$(require "Fargate vCPU" "$(price AmazonECS usagetype=USE1-Fargate-vCPU-Hours:perCPU)")
P_GB=$(require "Fargate GB" "$(price AmazonECS usagetype=USE1-Fargate-GB-Hours)")
P_RDS=$(require "RDS $RDS_CLASS" "$(price AmazonRDS instanceType=$RDS_CLASS databaseEngine=PostgreSQL deploymentOption=Single-AZ)")
P_RDS_GB=$(require "RDS gp3" "$(price AmazonRDS productFamily='Database Storage' volumeType='General Purpose-GP3' databaseEngine=PostgreSQL deploymentOption=Single-AZ)")
P_IPV4=$(require "IPv4 público" "$(price AmazonVPC usagetype=USE1-PublicIPv4:InUseAddress)")
P_ECR=$(require "ECR storage" "$(price AmazonECR usagetype=TimedStorage-ByteHrs)")
P_S3_GB=$(require "S3 storage" "$(price AmazonS3 usagetype=TimedStorage-ByteHrs)")
P_S3_PUT=$(require "S3 PUT" "$(price AmazonS3 usagetype=Requests-Tier1)")
P_S3_GET=$(require "S3 GET" "$(price AmazonS3 usagetype=Requests-Tier2)")
P_LOGS=$(require "Logs ingestão" "$(price AmazonCloudWatch usagetype=USE1-DataProcessing-Bytes)")

TODAY=$(date -u +%Y-%m-%d)

LC_ALL=C awk -v h="$HOURS" -v hm="$HOURS_PER_MONTH" -v extra="$EXTRA_TASK_HOURS" \
    -v vcpu="$FARGATE_VCPU" -v gb="$FARGATE_GB" -v stor="$RDS_STORAGE_GB" \
    -v img="$IMAGE_GB" -v logs="$LOG_GB" -v put="$S3_REQUESTS_PUT" -v get="$S3_REQUESTS_GET" \
    -v pv="$P_VCPU" -v pg="$P_GB" -v pr="$P_RDS" -v prs="$P_RDS_GB" -v pip="$P_IPV4" \
    -v pecr="$P_ECR" -v ps3="$P_S3_GB" -v pput="$P_S3_PUT" -v pget="$P_S3_GET" -v plog="$P_LOGS" \
    -v cls="$RDS_CLASS" -v today="$TODAY" '
function row(name, conf, rate, unit, subtotal) {
  printf "| %s | %s | %.7g | %s | %.4f |\n", name, conf, rate, unit, subtotal; total += subtotal
}
BEGIN {
  th = h + extra
  printf "Estimativa para %s h (consulta à AWS Pricing API em %s)\n\n", h, today
  print "| Recurso | Configuração | Tarifa (USD) | Unidade | Subtotal (USD) |"
  print "|---|---|---|---|---|"
  row("Fargate vCPU", vcpu " vCPU x " th " h", pv, "vCPU-hora", pv * vcpu * th)
  row("Fargate memória", gb " GB x " th " h", pg, "GB-hora", pg * gb * th)
  row("RDS PostgreSQL", cls " Single-AZ x " h " h", pr, "hora", pr * h)
  row("RDS armazenamento", stor " GB gp3", prs, "GB-mês", prs * stor * h / hm)
  row("IPv4 público (task)", "1 x " th " h", pip, "IP-hora", pip * th)
  row("ECR armazenamento", img " GB", pecr, "GB-mês", pecr * img * h / hm)
  row("S3 armazenamento", "< 1 MB", ps3, "GB-mês", ps3 * 0.001 * h / hm)
  row("S3 PUT/LIST", put " req", pput, "req", pput * put)
  row("S3 GET", get " req", pget, "req", pget * get)
  row("CloudWatch Logs", logs " GB ingeridos", plog, "GB", plog * logs)
  row("SSM Parameter Store", "parâmetros Standard", 0, "grátis", 0)
  row("Transferência de saída", "< 1 GB (100 GB/mês grátis)", 0, "GB", 0)
  printf "\n**Total estimado: US$ %.4f** para %s h", total, h
  printf " | custo por hora ~US$ %.4f | 24 h ~US$ %.2f\n", total / h, total / h * 24
}'
