#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# CUSTO DO QUE ESTÁ RODANDO AGORA
# ---------------------------------------------------------------------------
# Consulta os recursos realmente existentes na conta e calcula a taxa por
# hora. Não é o seu faturamento — é a velocidade com que o crédito está sendo
# consumido NESTE momento. O Cost Explorer mostra o passado com até 24h de
# atraso; isto mostra o presente.
#
# SOMENTE LEITURA.
#
#   ./scripts/custo.sh [--regiao us-east-1] [--credito 100]
# ---------------------------------------------------------------------------
set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/comum.sh"

REGIAO="us-east-1"
CREDITO="100"

while [ $# -gt 0 ]; do
  case "$1" in
    --regiao)  REGIAO="${2:-}"; shift 2 ;;
    --credito) CREDITO="${2:-}"; shift 2 ;;
    -h|--help)
      printf '%s\n' "custo.sh — taxa de consumo atual na AWS"
      printf '%s\n' "  ./scripts/custo.sh [--regiao us-east-1] [--credito 100]"
      exit 0 ;;
    *) morrer "Opção desconhecida: $1" ;;
  esac
done

exigir aws awk
aws_autenticado || morrer "Credenciais da AWS não configuradas ou inválidas."

# --- Tabela de preços -----------------------------------------------------
# us-east-1, on-demand, US$/hora. Sem array associativo (bash 3.2).
# Confira em https://calculator.aws — preço muda.
preco_instancia() {
  case "$1" in
    t3.nano)    echo 0.0052 ;; t3.micro)   echo 0.0104 ;;
    t3.small)   echo 0.0208 ;; t3.medium)  echo 0.0416 ;;
    t3.large)   echo 0.0832 ;; t3.xlarge)  echo 0.1664 ;;
    t3a.micro)  echo 0.0094 ;; t3a.small)  echo 0.0188 ;;
    t3a.medium) echo 0.0376 ;; t3a.large)  echo 0.0752 ;;
    m5.large)   echo 0.0960 ;; m5.xlarge)  echo 0.1920 ;;
    m5a.large)  echo 0.0860 ;; c5.large)   echo 0.0850 ;;
    c5.xlarge)  echo 0.1700 ;; r5.large)   echo 0.1260 ;;
    *)          echo "" ;;
  esac
}

PRECO_EKS=0.10          # por cluster
PRECO_NAT=0.045         # por gateway
PRECO_IPV4=0.005        # por IP público
PRECO_ALB=0.0225        # por load balancer (ALB/NLB)
PRECO_CLB=0.025         # classic
PRECO_EBS_GB_MES=0.08   # gp3

TOTAL_H=0
soma() { TOTAL_H=$(awk -v a="$TOTAL_H" -v b="$1" 'BEGIN{printf "%.6f", a+b}'); }
fmt()  { awk -v v="$1" 'BEGIN{printf "%.3f", v}'; }
fmt2() { awk -v v="$1" 'BEGIN{printf "%.2f", v}'; }

linha() {
  local rotulo="$1" qtd="$2" taxa="$3"
  [ "${qtd:-0}" -eq 0 ] 2>/dev/null && return 0
  local sub; sub=$(awk -v q="$qtd" -v t="$taxa" 'BEGIN{printf "%.6f", q*t}')
  soma "$sub"
  printf '  %s%2s x  US$ %s/h   = US$ %s/h\n' \
    "$(coluna "$rotulo" 26)" "$qtd" "$(fmt "$taxa")" "$(fmt "$sub")"
}

contar() { # conta campos não vazios de uma saída `--output text`
  printf '%s' "$1" | tr '\t' '\n' | grep -v '^[[:space:]]*$' | grep -cv '^None$'
}

titulo "Custo em tempo real — $REGIAO"
info "Conta: $(conta_aws)"
echo

# --- Coleta ---------------------------------------------------------------
N_EKS=$(contar "$(aws eks list-clusters --region "$REGIAO" --query 'clusters' --output text 2>/dev/null)")
N_NAT=$(contar "$(aws ec2 describe-nat-gateways --region "$REGIAO" \
          --filter Name=state,Values=available \
          --query 'NatGateways[].NatGatewayId' --output text 2>/dev/null)")
N_ALB=$(contar "$(aws elbv2 describe-load-balancers --region "$REGIAO" \
          --query 'LoadBalancers[].LoadBalancerName' --output text 2>/dev/null)")
N_CLB=$(contar "$(aws elb describe-load-balancers --region "$REGIAO" \
          --query 'LoadBalancerDescriptions[].LoadBalancerName' --output text 2>/dev/null)")
N_IP=$(contar "$(aws ec2 describe-addresses --region "$REGIAO" \
          --query 'Addresses[].PublicIp' --output text 2>/dev/null)")

printf '%s\n' "${C_NEG}Recursos ativos${C_OFF}"
linha "Cluster EKS"            "$N_EKS" "$PRECO_EKS"
linha "NAT Gateway"            "$N_NAT" "$PRECO_NAT"
linha "Load Balancer ALB/NLB"  "$N_ALB" "$PRECO_ALB"
linha "Load Balancer clássico" "$N_CLB" "$PRECO_CLB"
linha "IPv4 público"           "$N_IP"  "$PRECO_IPV4"

# --- Instâncias EC2, agrupadas por tipo -----------------------------------
INSTANCIAS=$(aws ec2 describe-instances --region "$REGIAO" \
  --filters Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].InstanceType' --output text 2>/dev/null \
  | tr '\t' '\n' | grep -v '^[[:space:]]*$' | sort | uniq -c)

if [ -n "$INSTANCIAS" ]; then
  printf '%s\n' "$INSTANCIAS" | while read -r qtd tipo; do
    [ -n "$tipo" ] || continue
    p="$(preco_instancia "$tipo")"
    if [ -z "$p" ]; then
      printf '  %s%2s x  %s\n' "$(coluna "EC2 $tipo" 26)" "$qtd" "preço não tabelado"
    else
      sub=$(awk -v q="$qtd" -v t="$p" 'BEGIN{printf "%.6f", q*t}')
      printf '  %s%2s x  US$ %s/h   = US$ %s/h\n' \
        "$(coluna "EC2 $tipo" 26)" "$qtd" "$(fmt "$p")" "$(fmt "$sub")"
      printf '%s\n' "$sub" >> "${TMPDIR:-/tmp}/.custo_ec2.$$"
    fi
  done
  # O while acima roda em subshell (pipe): o total vem pelo arquivo.
  if [ -f "${TMPDIR:-/tmp}/.custo_ec2.$$" ]; then
    EC2_H=$(awk '{s+=$1} END{printf "%.6f", s}' "${TMPDIR:-/tmp}/.custo_ec2.$$")
    rm -f "${TMPDIR:-/tmp}/.custo_ec2.$$"
    soma "$EC2_H"
  fi
fi

# --- EBS ------------------------------------------------------------------
GB=$(aws ec2 describe-volumes --region "$REGIAO" \
      --query 'Volumes[].Size' --output text 2>/dev/null \
      | tr '\t' '\n' | awk '{s+=$1} END{printf "%d", s}')
if [ "${GB:-0}" -gt 0 ]; then
  EBS_H=$(awk -v g="$GB" -v p="$PRECO_EBS_GB_MES" 'BEGIN{printf "%.6f", g*p/730}')
  soma "$EBS_H"
  printf '  %s%4s GB         = US$ %s/h\n' "$(coluna "Volumes EBS" 26)" "$GB" "$(fmt "$EBS_H")"
fi

# --- Totais ---------------------------------------------------------------
echo
printf '%s\n' "$(printf '%.0s─' $(seq 1 60))"

if awk -v t="$TOTAL_H" 'BEGIN{exit !(t<0.0001)}'; then
  ok "Nada cobrando nesta região. Taxa: US$ 0,00/h"
  exit 0
fi

DIA=$(awk -v t="$TOTAL_H"  'BEGIN{printf "%.2f", t*24}')
MES=$(awk -v t="$TOTAL_H"  'BEGIN{printf "%.2f", t*730}')
HORAS=$(awk -v t="$TOTAL_H" -v c="$CREDITO" 'BEGIN{printf "%.0f", c/t}')
DIAS=$(awk -v t="$TOTAL_H"  -v c="$CREDITO" 'BEGIN{printf "%.1f", c/t/24}')

# A cor fica FORA de `coluna`: ${#} conta os caracteres de escape e
# desalinharia a coluna.
printf '  %s%s%sUS$ %s\n' "$C_NEG" "$(coluna "Por hora" 26)" "$C_OFF" "$(fmt "$TOTAL_H")"
printf '  %sUS$ %s\n' "$(coluna "Por dia (24h)" 26)" "$DIA"
printf '  %sUS$ %s\n' "$(coluna "Por mês (730h)" 26)" "$MES"
echo
printf '  %s%s horas  (%s dias)\n' \
  "$(coluna "US\$ $CREDITO duram" 26)" "$HORAS" "$DIAS"

echo
if awk -v d="$DIAS" 'BEGIN{exit !(d<3)}'; then
  erro "Menos de 3 dias de crédito. Desligue o que não estiver em uso."
elif awk -v d="$DIAS" 'BEGIN{exit !(d<10)}'; then
  aviso "Menos de 10 dias de crédito restantes nesta taxa."
else
  info "Para parar o consumo: ./scripts/destroy.sh"
fi

aviso "Estimativa de preços on-demand us-east-1. Não inclui transferência de"
aviso "dados, processamento do NAT nem CloudWatch. Confira no Cost Explorer."
