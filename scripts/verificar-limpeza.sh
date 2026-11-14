#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# VERIFICAR LIMPEZA
# ---------------------------------------------------------------------------
# Confere se sobrou algo cobrando na AWS depois do destroy.
#
# SOMENTE LEITURA: não apaga nada. Lista o que ainda existe.
#
# Por que é necessário: o `terraform destroy` remove o que o Terraform criou.
# Recursos que o KUBERNETES criou — Load Balancer de um Service
# type=LoadBalancer, volume EBS de um PersistentVolumeClaim — não estão no
# state e sobrevivem ao destroy, continuando a cobrar.
#
#   ./scripts/verificar-limpeza.sh [regiao]
# ---------------------------------------------------------------------------
set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/comum.sh"

REGIAO="${1:-us-east-1}"
ACHOU=0

case "${1:-}" in
  -h|--help)
    printf '%s\n' "verificar-limpeza.sh — confere se sobrou recurso cobrando"
    printf '%s\n' "  ./scripts/verificar-limpeza.sh [regiao]"
    exit 0 ;;
esac

exigir aws
aws_autenticado || morrer "Credenciais da AWS não configuradas ou inválidas."

checar() {
  local nome="$1" custo="$2" saida="$3"
  if [ -n "$saida" ] && [ "$saida" != "None" ]; then
    printf '  %s%s%s %s%s\n' "$C_VERM" "●" "$C_OFF" "$(coluna "$nome" 29)" "$custo"
    printf '%s\n' "$saida" | tr '\t' ' ' | sed 's/^/        /'
    ACHOU=1
  else
    printf '  %s%s%s %slimpo\n' "$C_VERD" "○" "$C_OFF" "$(coluna "$nome" 29)"
  fi
}

titulo "Verificando limpeza — $REGIAO"
info "Conta: $(conta_aws)"

printf '\n%s\n' "${C_NEG}O que ainda existe e cobra${C_OFF}"

checar "Cluster EKS" "US\$ 0,10/h cada" \
  "$(aws eks list-clusters --region "$REGIAO" --query 'clusters' --output text 2>/dev/null)"

checar "NAT Gateway" "US\$ 0,045/h cada" \
  "$(aws ec2 describe-nat-gateways --region "$REGIAO" \
      --filter Name=state,Values=available \
      --query 'NatGateways[].NatGatewayId' --output text 2>/dev/null)"

checar "Instâncias EC2 ligadas" "varia por tipo" \
  "$(aws ec2 describe-instances --region "$REGIAO" \
      --filters Name=instance-state-name,Values=running,pending \
      --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null)"

# Criados pelo Kubernetes, não pelo Terraform. São os que mais escapam.
checar "Load Balancer ALB/NLB" "US\$ ~0,0225/h cada" \
  "$(aws elbv2 describe-load-balancers --region "$REGIAO" \
      --query 'LoadBalancers[].LoadBalancerName' --output text 2>/dev/null)"

checar "Load Balancer clássico" "US\$ ~0,025/h cada" \
  "$(aws elb describe-load-balancers --region "$REGIAO" \
      --query 'LoadBalancerDescriptions[].LoadBalancerName' --output text 2>/dev/null)"

checar "Volumes EBS órfãos" "US\$ 0,08/GB-mês" \
  "$(aws ec2 describe-volumes --region "$REGIAO" \
      --filters Name=status,Values=available \
      --query 'Volumes[].[VolumeId,Size]' --output text 2>/dev/null)"

checar "IPs elásticos soltos" "US\$ 0,005/h cada" \
  "$(aws ec2 describe-addresses --region "$REGIAO" \
      --query 'Addresses[?AssociationId==null].PublicIp' --output text 2>/dev/null)"

printf '\n%s\n' "${C_NEG}Sem custo direto, mas indica destroy incompleto${C_OFF}"

checar "VPC não-padrão" "grátis" \
  "$(aws ec2 describe-vpcs --region "$REGIAO" \
      --query 'Vpcs[?IsDefault==`false`].VpcId' --output text 2>/dev/null)"

checar "Grupos de log do projeto" "US\$ 0,03/GB-mês" \
  "$(aws logs describe-log-groups --region "$REGIAO" \
      --query 'logGroups[?contains(logGroupName, `eks`) || contains(logGroupName, `vpc`)].logGroupName' \
      --output text 2>/dev/null)"

echo
if [ "$ACHOU" -eq 1 ]; then
  printf '%s\n' "${C_VERM}${C_NEG}Ainda há recursos ativos.${C_OFF}"
  echo
  info "Causas comuns:"
  info "  Load Balancer  criado por um Service type=LoadBalancer no cluster."
  info "                 Apague o Service e rode ./scripts/destroy.sh de novo."
  info "  Volume EBS     veio de um PersistentVolumeClaim (ex.: Prometheus)."
  info "  VPC sobrando   o destroy falhou, em geral por interface de rede de"
  info "                 Load Balancer presa na subnet."
  echo
  info "Taxa de consumo atual:  ./scripts/custo.sh"
  exit 1
else
  printf '%s\n' "${C_VERD}${C_NEG}Nada ativo nesta região.${C_OFF}"
  echo
  info "Confirme amanhã no Cost Explorer: o faturamento leva até 24h para atualizar."
  exit 0
fi
