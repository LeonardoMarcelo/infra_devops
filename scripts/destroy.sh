#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# DESTROY ORDENADO
# ---------------------------------------------------------------------------
# `terraform destroy` sozinho NÃO basta nesta infraestrutura.
#
# O Terraform remove o que o Terraform criou. Recursos que o KUBERNETES criou
# na AWS — Load Balancer de um Service type=LoadBalancer, volume EBS de um
# PersistentVolumeClaim — não estão no state. Eles sobrevivem ao destroy e
# continuam cobrando. Pior: as interfaces de rede do Load Balancer ficam
# presas nas subnets, o destroy tenta apagar a subnet por ~20 minutos e
# FALHA, deixando cluster, NAT e nós de pé.
#
# Este script faz a ordem correta:
#   1. remove o que o Kubernetes criou na AWS e espera sumir
#   2. destrói a observabilidade  (roda dentro do cluster)
#   3. destrói a camada de dados  (depende da VPC e do SG dos nós)
#   4. destrói a infraestrutura base
#   5. verifica que nada sobrou
#
# A ordem é o inverso exato da aplicação. Destruir a base antes da camada de
# dados deixa regras de security group apontando para um SG que não existe
# mais, e o destroy da camada de dados passa a falhar.
#
#   ./scripts/destroy.sh --help
# ---------------------------------------------------------------------------
set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/comum.sh"

CAMADA="tudo"
REGIAO="us-east-1"
DRY_RUN=0
AUTO_SIM=0
PULAR_K8S=0

uso() {
  cat <<EOF
${C_NEG}destroy.sh${C_OFF} — desliga a infraestrutura na ordem correta

  ./scripts/destroy.sh [opções]

Opções
  --camada <nome>   tudo (padrão) | producao | data | observability
  --regiao <r>      região da AWS (padrão: us-east-1)
  --dry-run         mostra o que seria destruído, sem destruir
  --sim             pula a confirmação interativa (para automação)
  --pular-k8s       não tenta limpar recursos do Kubernetes
  -h, --help        esta ajuda

Ordem com --camada tudo
  kubernetes -> observability -> data -> producao
  (o inverso exato da aplicação)

Variáveis de ambiente
  TF_BACKEND_BUCKET      bucket do state (obrigatória se não houver init local)
  TF_BACKEND_KEY         padrão: producao/infra.tfstate
  TF_BACKEND_KEY_DATA    padrão: producao/data.tfstate
  TF_BACKEND_KEY_OBS     padrão: producao/observability.tfstate

Exemplos
  ./scripts/destroy.sh --dry-run
  ./scripts/destroy.sh --camada observability
  ./scripts/destroy.sh --camada data          # só os bancos
  TF_BACKEND_BUCKET=meu-bucket ./scripts/destroy.sh
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --camada)    CAMADA="${2:-}"; shift 2 ;;
    --regiao)    REGIAO="${2:-}"; shift 2 ;;
    --dry-run)   DRY_RUN=1; shift ;;
    --sim)       AUTO_SIM=1; shift ;;
    --pular-k8s) PULAR_K8S=1; shift ;;
    -h|--help)   uso; exit 0 ;;
    *)           erro "Opção desconhecida: $1"; echo; uso; exit 1 ;;
  esac
done
export REGIAO

case "$CAMADA" in
  tudo|producao|data|observability) ;;
  *) morrer "Camada inválida: '$CAMADA'. Use tudo, producao, data ou observability." ;;
esac

# As camadas usam `terraform_remote_state` para se ligarem entre si; o
# Terraform precisa do bucket como variável de entrada, não só no backend.
if [ -n "${TF_BACKEND_BUCKET:-}" ]; then
  export TF_VAR_state_bucket="$TF_BACKEND_BUCKET"
fi

# ===========================================================================
# ETAPA 0 — Pré-requisitos e contexto
# ===========================================================================
titulo "Destroy — camada: $CAMADA"

exigir terraform aws
[ "$PULAR_K8S" -eq 1 ] || exigir kubectl

aws_autenticado || morrer "Credenciais da AWS não configuradas ou inválidas."

DIR_PROD="$(camada_dir producao)"
DIR_OBS="$(camada_dir observability)"
CLUSTER="$(ler_tfvar "$DIR_PROD" cluster_name)"
[ -n "$CLUSTER" ] || morrer "Não foi possível ler cluster_name de $DIR_PROD/terraform.tfvars"

info "Conta AWS:  $(conta_aws)"
info "Identidade: $(identidade_aws)"
info "Região:     $REGIAO"
info "Cluster:    $CLUSTER"
[ "$DRY_RUN" -eq 1 ] && aviso "DRY RUN — nada será destruído"

# ===========================================================================
# ETAPA 0.1 — Confirmação
# ===========================================================================
if [ "$DRY_RUN" -eq 0 ] && [ "$AUTO_SIM" -eq 0 ]; then
  echo
  aviso "Isto REMOVE infraestrutura. A ação não tem desfazer."
  confirmar_digitando "$CLUSTER" "para confirmar a destruição" \
    || morrer "Confirmação não conferiu. Nada foi feito."
fi

# ===========================================================================
# ETAPA 1 — Recursos que o Kubernetes criou na AWS
# ===========================================================================
limpar_kubernetes() {
  passo "Etapa 1/5 — recursos criados pelo Kubernetes"

  if ! cluster_existe "$CLUSTER"; then
    ok "Cluster '$CLUSTER' não existe. Nada a limpar aqui."
    return 0
  fi

  info "Configurando o kubectl..."
  if ! aws eks update-kubeconfig --name "$CLUSTER" --region "$REGIAO" >/dev/null 2>&1; then
    aviso "Não foi possível configurar o kubectl. Pulando a limpeza do Kubernetes."
    aviso "Se houver Service type=LoadBalancer no cluster, o destroy pode falhar."
    return 0
  fi

  if ! kubectl_conectado; then
    aviso "Sem acesso à API do cluster. Pulando a limpeza do Kubernetes."
    return 0
  fi

  # Services type=LoadBalancer -> cada um criou um ELB/NLB na AWS
  local svcs
  svcs=$(kubectl get svc --all-namespaces \
          -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' \
          2>/dev/null | grep -v '^[[:space:]]*$')

  if [ -n "$svcs" ]; then
    info "Services type=LoadBalancer encontrados:"
    printf '%s\n' "$svcs" | sed 's/^/      /'
    if [ "$DRY_RUN" -eq 0 ]; then
      printf '%s\n' "$svcs" | while read -r ns nome; do
        [ -n "$nome" ] || continue
        info "removendo svc/$nome em $ns"
        kubectl delete svc "$nome" -n "$ns" --timeout=120s >/dev/null 2>&1 \
          || aviso "falhou ao remover svc/$nome"
      done
    fi
  else
    ok "Nenhum Service type=LoadBalancer"
  fi

  # Ingresses -> cada um pode ter criado um ALB
  local ings
  ings=$(kubectl get ingress --all-namespaces \
          -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' \
          2>/dev/null | grep -v '^[[:space:]]*$')

  if [ -n "$ings" ]; then
    info "Ingresses encontrados:"
    printf '%s\n' "$ings" | sed 's/^/      /'
    if [ "$DRY_RUN" -eq 0 ]; then
      printf '%s\n' "$ings" | while read -r ns nome; do
        [ -n "$nome" ] || continue
        info "removendo ingress/$nome em $ns"
        kubectl delete ingress "$nome" -n "$ns" --timeout=120s >/dev/null 2>&1 \
          || aviso "falhou ao remover ingress/$nome"
      done
    fi
  else
    ok "Nenhum Ingress"
  fi

  [ "$DRY_RUN" -eq 1 ] && return 0
  [ -z "$svcs" ] && [ -z "$ings" ] && return 0

  # Apagar o objeto no Kubernetes só PEDE a remoção do Load Balancer.
  # A AWS leva algum tempo. Destruir a VPC antes disso é o que trava.
  info "Aguardando os Load Balancers sumirem da AWS..."
  local tentativa=0 restantes
  while [ "$tentativa" -lt 30 ]; do
    restantes=$(
      { aws elbv2 describe-load-balancers --region "$REGIAO" \
          --query 'LoadBalancers[].LoadBalancerName' --output text 2>/dev/null
        aws elb describe-load-balancers --region "$REGIAO" \
          --query 'LoadBalancerDescriptions[].LoadBalancerName' --output text 2>/dev/null
      } | tr '\t' '\n' | grep -v '^[[:space:]]*$' | grep -v '^None$'
    )
    if [ -z "$restantes" ]; then
      ok "Todos os Load Balancers foram removidos"
      return 0
    fi
    tentativa=$(( tentativa + 1 ))
    printf '\r      ainda existem %s (tentativa %s/30)   ' \
      "$(printf '%s' "$restantes" | wc -l | tr -d ' ')" "$tentativa"
    sleep 10
  done
  echo
  aviso "Load Balancers ainda presentes após 5 minutos:"
  printf '%s\n' "$restantes" | sed 's/^/      /'
  aviso "O destroy pode falhar. Remova-os pelo console e rode de novo."
}

# ===========================================================================
# ETAPAS 2 e 3 — Camadas do Terraform
# ===========================================================================
destruir_camada() {
  local nome="$1" rotulo="$2" dir key
  dir="$(camada_dir "$nome")" || morrer "Camada desconhecida: $nome"
  key="$(camada_key_padrao "$nome")"

  passo "$rotulo — $(basename "$dir")"

  if [ ! -d "$dir" ]; then
    ok "Diretório não existe. Nada a destruir."
    return 0
  fi

  tf_init "$dir" "$key"

  if ! tf_tem_recursos "$dir"; then
    ok "State vazio. Nada a destruir nesta camada."
    return 0
  fi

  local n
  n=$( cd "$dir" && terraform state list 2>/dev/null | wc -l | tr -d ' ' )
  info "$n recursos no state"

  if [ "$DRY_RUN" -eq 1 ]; then
    info "Plano de destruição (dry run):"
    ( cd "$dir" && terraform plan -destroy -input=false -no-color 2>&1 \
        | tail -25 | sed 's/^/      /' )
    return 0
  fi

  info "Destruindo... (pode levar de 10 a 20 minutos)"
  if ( cd "$dir" && terraform destroy -auto-approve -input=false -lock-timeout=5m ); then
    ok "$rotulo concluída"
  else
    erro "Falha ao destruir $(basename "$dir")."
    erro "Causa mais comum: interface de rede de Load Balancer presa na subnet."
    erro "Remova os Load Balancers pelo console e rode este script de novo."
    return 1
  fi
}

# ===========================================================================
# Execução
# ===========================================================================
FALHOU=0

if [ "$PULAR_K8S" -eq 0 ] && [ "$CAMADA" != "observability" ] && [ "$CAMADA" != "data" ]; then
  limpar_kubernetes
elif [ "$PULAR_K8S" -eq 1 ]; then
  passo "Etapa 1/5 — recursos do Kubernetes"
  aviso "Pulada por --pular-k8s"
fi

# Ordem inversa da aplicação. A observabilidade roda dentro do cluster e lê
# a camada de dados; a camada de dados referencia a VPC e o security group
# dos nós. Destruir a base antes deixaria as outras duas sem como se
# desfazer.
if [ "$CAMADA" = "tudo" ] || [ "$CAMADA" = "observability" ]; then
  destruir_camada observability "Etapa 2/5 — observabilidade" || FALHOU=1
fi

if [ "$FALHOU" -eq 0 ] && { [ "$CAMADA" = "tudo" ] || [ "$CAMADA" = "data" ]; }; then
  destruir_camada data "Etapa 3/5 — bancos de dados" || FALHOU=1
fi

if [ "$FALHOU" -eq 0 ] && { [ "$CAMADA" = "tudo" ] || [ "$CAMADA" = "producao" ]; }; then
  destruir_camada producao "Etapa 4/5 — infraestrutura base" || FALHOU=1
fi

# ===========================================================================
# ETAPA 4 — Conferência
# ===========================================================================
passo "Etapa 5/5 — conferindo o que sobrou"

if [ "$DRY_RUN" -eq 1 ]; then
  aviso "Dry run: conferência pulada."
  echo
  info "Para destruir de verdade, rode sem --dry-run."
  exit 0
fi

if [ -x "$SCRIPTS_DIR/verificar-limpeza.sh" ]; then
  "$SCRIPTS_DIR/verificar-limpeza.sh" "$REGIAO" || FALHOU=1
else
  aviso "verificar-limpeza.sh não encontrado; conferência pulada."
fi

echo
if [ "$FALHOU" -eq 0 ]; then
  printf '%s\n' "${C_VERD}${C_NEG}Tudo desligado.${C_OFF}"
  info "Confirme amanhã no Cost Explorer: o faturamento leva até 24h para atualizar."
  exit 0
else
  printf '%s\n' "${C_VERM}${C_NEG}Terminou com pendências.${C_OFF} Veja as mensagens acima."
  exit 1
fi
