#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# PREFLIGHT — conferência antes do primeiro apply
# ---------------------------------------------------------------------------
# Checa o que costuma fazer o apply falhar no meio, ou gastar mais do que a
# pessoa esperava. Roda em segundos e não cria nada.
#
# SOMENTE LEITURA.
#
#   ./scripts/preflight.sh [--regiao us-east-1]
# ---------------------------------------------------------------------------
set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/comum.sh"

REGIAO="us-east-1"
FALHAS=0
ALERTAS=0

while [ $# -gt 0 ]; do
  case "$1" in
    --regiao) REGIAO="${2:-}"; shift 2 ;;
    -h|--help)
      printf '%s\n' "preflight.sh — conferência antes do apply"
      printf '%s\n' "  ./scripts/preflight.sh [--regiao us-east-1]"
      exit 0 ;;
    *) morrer "Opção desconhecida: $1" ;;
  esac
done
export REGIAO

falha()  { erro "$*"; FALHAS=$(( FALHAS + 1 )); }
alerta() { aviso "$*"; ALERTAS=$(( ALERTAS + 1 )); }

DIR_PROD="$(camada_dir producao)"

# ===========================================================================
titulo "1. Ferramentas"
# ===========================================================================
for c in terraform aws; do
  if command -v "$c" >/dev/null 2>&1; then ok "$c encontrado"; else falha "$c não encontrado"; fi
done
for c in kubectl helm; do
  if command -v "$c" >/dev/null 2>&1; then ok "$c encontrado"; else alerta "$c não encontrado (necessário só para usar o cluster)"; fi
done

if command -v terraform >/dev/null 2>&1; then
  V=$(terraform version -json 2>/dev/null | sed -n 's/.*"terraform_version": *"\([^"]*\)".*/\1/p')
  [ -n "$V" ] || V=$(terraform version | head -1 | sed 's/Terraform v//')
  case "$V" in
    1.17.*) ok "Terraform $V (bate com a versão fixada na pipeline)" ;;
    *)      alerta "Terraform $V — a raiz exige ~> 1.17 e a pipeline usa 1.17.2" ;;
  esac
fi

# ===========================================================================
titulo "2. Credenciais da AWS"
# ===========================================================================
if aws_autenticado; then
  ok "Autenticado como $(identidade_aws)"
  info "Conta: $(conta_aws)  |  Região alvo: $REGIAO"
else
  falha "Credenciais não configuradas ou inválidas (aws sts get-caller-identity)"
fi

# ===========================================================================
titulo "3. Backend do state"
# ===========================================================================
if [ -z "${TF_BACKEND_BUCKET:-}" ]; then
  if tf_inicializado "$DIR_PROD"; then
    ok "Diretório já inicializado (backend configurado antes)"
  else
    alerta "TF_BACKEND_BUCKET não definido e o diretório não está inicializado"
    info "  export TF_BACKEND_BUCKET=<seu-bucket>"
  fi
else
  B="$TF_BACKEND_BUCKET"
  if aws s3api head-bucket --bucket "$B" >/dev/null 2>&1; then
    ok "Bucket '$B' existe e está acessível"

    VERS=$(aws s3api get-bucket-versioning --bucket "$B" --query Status --output text 2>/dev/null)
    if [ "$VERS" = "Enabled" ]; then
      ok "Versionamento habilitado (dá para recuperar um state perdido)"
    else
      alerta "Versionamento DESABILITADO no bucket. Um state corrompido vira perda total."
    fi

    PUB=$(aws s3api get-public-access-block --bucket "$B" \
            --query 'PublicAccessBlockConfiguration.BlockPublicAcls' --output text 2>/dev/null)
    if [ "$PUB" = "True" ]; then
      ok "Acesso público bloqueado"
    else
      alerta "Bloqueio de acesso público não confirmado. O state descreve toda a infraestrutura."
    fi
  else
    falha "Bucket '$B' não existe ou não está acessível"
  fi
fi

# ===========================================================================
titulo "4. Proteção financeira"
# ===========================================================================
# Budgets é um serviço global: consultado em us-east-1.
N_BUDGET=$(aws budgets describe-budgets --account-id "$(conta_aws)" \
            --query 'length(Budgets)' --output text 2>/dev/null)
case "${N_BUDGET:-}" in
  ''|None) alerta "Não foi possível consultar os budgets (falta permissão?). Confira no console." ;;
  0)       falha "NENHUM budget configurado. Crie um antes do apply — ver resumido.md, seção 3.1." ;;
  *)       ok "$N_BUDGET budget(s) configurado(s)" ;;
esac

# ===========================================================================
titulo "5. Configuração e custo previsto"
# ===========================================================================
if [ ! -f "$DIR_PROD/terraform.tfvars" ]; then
  falha "terraform.tfvars não encontrado em $DIR_PROD"
else
  CLUSTER="$(ler_tfvar "$DIR_PROD" cluster_name)"
  K8S="$(ler_tfvar "$DIR_PROD" kubernetes_version)"
  info "Cluster: $CLUSTER  |  Kubernetes: $K8S"

  # NAT: a maior alavanca de custo do projeto
  SINGLE=$(grep -E '^[[:space:]]*single_nat_gateway[[:space:]]*=' "$DIR_PROD/terraform.tfvars" \
            | head -1 | sed -E 's/.*=[[:space:]]*([a-z]+).*/\1/')
  N_AZ=$(grep -E '^[[:space:]]*availability_zones[[:space:]]*=' "$DIR_PROD/terraform.tfvars" \
          | head -1 | tr ',' '\n' | grep -c '"')

  if [ "$SINGLE" = "true" ]; then
    N_NAT=1; ok "single_nat_gateway = true → 1 NAT Gateway"
  else
    N_NAT="${N_AZ:-3}"
    alerta "single_nat_gateway = false → $N_NAT NAT Gateways (US\$ $(awk -v n="$N_NAT" 'BEGIN{printf "%.2f", n*0.045*730}')/mês)"
    info "  Para estudo, mude para 'true' e economize US\$ $(awk -v n="$N_NAT" 'BEGIN{printf "%.2f", (n-1)*0.05*730}')/mês"
  fi

  # Nós
  TIPO=$(grep -E '^[[:space:]]*instance_types[[:space:]]*=' "$DIR_PROD/terraform.tfvars" \
          | head -1 | sed -E 's/.*\["([^"]*)".*/\1/')
  QTD=$(grep -E '^[[:space:]]*desired_size[[:space:]]*=' "$DIR_PROD/terraform.tfvars" \
          | head -1 | sed -E 's/[^0-9]*([0-9]+).*/\1/')
  info "Nós: ${QTD:-?} x ${TIPO:-?}"

  case "$TIPO" in
    t3.small|t3.micro|t3.nano|t3a.small|t3a.micro)
      alerta "'$TIPO' não comporta a stack de monitoramento (ela pede ~4GB; o nó tem menos)."
      info "  Se for aplicar environments/production-observability, use t3.medium." ;;
  esac

  # Addon necessário para volumes
  if grep -qE '^[[:space:]]*cluster_addons[[:space:]]*=[[:space:]]*\{\}' "$DIR_PROD/terraform.tfvars"; then
    alerta "cluster_addons vazio: sem aws-ebs-csi-driver, todo PVC fica em Pending."
  fi

  # Exposição da API
  if grep -qE '0\.0\.0\.0/0' "$DIR_PROD/terraform.tfvars"; then
    alerta "Endpoint da API aberto para 0.0.0.0/0. Restrinja se você tiver IP fixo."
  fi

  # Custo previsto
  CUSTO_H=$(awk -v nat="$N_NAT" -v q="${QTD:-2}" 'BEGIN{
    preco_no = 0.0208   # assume t3.small; ajuste se mudar o tipo
    printf "%.3f", 0.10 + nat*0.045 + nat*0.005 + q*preco_no + 0.0044
  }')
  echo
  # Cor fora de `coluna`: ${#} conta escapes e desalinharia.
  printf '  %s%s%sUS$ %s/h  ·  US$ %s/dia  ·  US$ %s/mês\n' \
    "$C_NEG" "$(coluna "Custo previsto" 26)" "$C_OFF" \
    "$CUSTO_H" \
    "$(awk -v c="$CUSTO_H" 'BEGIN{printf "%.2f", c*24}')" \
    "$(awk -v c="$CUSTO_H" 'BEGIN{printf "%.2f", c*730}')"
  printf '  %s%s dias\n' "$(coluna "US\$ 100 duram" 26)" \
    "$(awk -v c="$CUSTO_H" 'BEGIN{printf "%.1f", 100/c/24}')"
fi

# ===========================================================================
titulo "6. Sintaxe do Terraform"
# ===========================================================================
if command -v terraform >/dev/null 2>&1; then
  if ( cd "$RAIZ" && terraform fmt -check -recursive >/dev/null 2>&1 ); then
    ok "Formatação em dia"
  else
    alerta "Há arquivos fora do padrão. Rode: terraform fmt -recursive"
  fi
else
  alerta "terraform ausente; validação pulada"
fi

# ===========================================================================
echo
printf '%s\n' "$(printf '%.0s─' $(seq 1 60))"
if [ "$FALHAS" -gt 0 ]; then
  printf '%s\n' "${C_VERM}${C_NEG}$FALHAS impedimento(s) e $ALERTAS alerta(s).${C_OFF} Resolva os impedimentos antes do apply."
  exit 1
elif [ "$ALERTAS" -gt 0 ]; then
  printf '%s\n' "${C_AMAR}${C_NEG}Pronto para o apply, com $ALERTAS alerta(s).${C_OFF} Leia acima e decida."
  exit 0
else
  printf '%s\n' "${C_VERD}${C_NEG}Tudo certo para o apply.${C_OFF}"
  exit 0
fi
