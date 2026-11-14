#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# BIBLIOTECA COMUM
# ---------------------------------------------------------------------------
# Funções compartilhadas pelos scripts de scripts/. Não executa nada sozinha:
# é feita para ser carregada com `source`.
#
# Compatível com bash 3.2 (o padrão do macOS): sem array associativo,
# sem ${var,,}, sem mapfile.
# ---------------------------------------------------------------------------

# Evita carregar duas vezes quando um script chama outro.
[ -n "${__COMUM_CARREGADO:-}" ] && return 0
__COMUM_CARREGADO=1

# --- Raiz do projeto ------------------------------------------------------
# Resolvida a partir da localização desta própria biblioteca, para os scripts
# funcionarem de qualquer diretório.
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(dirname "$LIB_DIR")"
RAIZ="$(dirname "$SCRIPTS_DIR")"
export LIB_DIR SCRIPTS_DIR RAIZ

# --- Cores ----------------------------------------------------------------
# Desligadas quando a saída não é um terminal (pipe, arquivo, CI).
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_VERM=$'\033[31m'; C_VERD=$'\033[32m'; C_AMAR=$'\033[33m'
  C_AZUL=$'\033[34m'; C_NEG=$'\033[1m';  C_OFF=$'\033[0m'
else
  C_VERM=''; C_VERD=''; C_AMAR=''; C_AZUL=''; C_NEG=''; C_OFF=''
fi

# --- Saída ----------------------------------------------------------------
info()   { printf '%s\n' "  $*"; }
ok()     { printf '%s\n' "  ${C_VERD}✓${C_OFF} $*"; }
aviso()  { printf '%s\n' "  ${C_AMAR}!${C_OFF} $*"; }
erro()   { printf '%s\n' "  ${C_VERM}✗${C_OFF} $*" >&2; }
passo()  { printf '\n%s\n' "${C_AZUL}${C_NEG}▸ $*${C_OFF}"; }
titulo() { printf '\n%s\n%s\n' "${C_NEG}$*${C_OFF}" "$(printf '%.0s─' $(seq 1 60))"; }

morrer() { erro "$*"; exit 1; }

# Padding que conta caracteres, não bytes — rótulo com acento desalinha o
# %-Ns do printf.
coluna() {
  local texto="$1" largura="${2:-30}"
  local pad=$(( largura - ${#texto} ))
  [ "$pad" -lt 1 ] && pad=1
  printf '%s%*s' "$texto" "$pad" ""
}

# --- Pré-requisitos -------------------------------------------------------
exigir() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || morrer "Comando '$cmd' não encontrado. Instale antes de continuar."
  done
}

aws_autenticado() {
  aws sts get-caller-identity >/dev/null 2>&1
}

conta_aws() {
  aws sts get-caller-identity --query Account --output text 2>/dev/null
}

identidade_aws() {
  aws sts get-caller-identity --query Arn --output text 2>/dev/null
}

# --- Confirmação ----------------------------------------------------------
# Exige digitar um texto exato. Usado antes de qualquer ação destrutiva:
# "s/n" é fácil demais de responder no automático.
confirmar_digitando() {
  local esperado="$1" rotulo="${2:-para confirmar}"
  local resposta
  printf '%s' "  Digite ${C_NEG}${esperado}${C_OFF} ${rotulo}: "
  read -r resposta
  [ "$resposta" = "$esperado" ]
}

confirmar_sn() {
  local pergunta="$1" resposta
  printf '%s' "  $pergunta [s/N]: "
  read -r resposta
  case "$resposta" in [sSyY]*) return 0 ;; *) return 1 ;; esac
}

# --- Camadas --------------------------------------------------------------
# Nome amigável -> diretório. Sem array associativo, por causa do bash 3.2.
camada_dir() {
  case "$1" in
    producao|production|base)  printf '%s' "$RAIZ/environments/production" ;;
    data|dados|banco)          printf '%s' "$RAIZ/environments/production-data" ;;
    observability|observabilidade|obs)
                               printf '%s' "$RAIZ/environments/production-observability" ;;
    *) return 1 ;;
  esac
}

camada_key_padrao() {
  case "$1" in
    producao|production|base)  printf '%s' "${TF_BACKEND_KEY:-producao/infra.tfstate}" ;;
    data|dados|banco)          printf '%s' "${TF_BACKEND_KEY_DATA:-producao/data.tfstate}" ;;
    observability|observabilidade|obs)
                               printf '%s' "${TF_BACKEND_KEY_OBS:-producao/observability.tfstate}" ;;
    *) return 1 ;;
  esac
}

# --- Terraform ------------------------------------------------------------
# Um diretório está inicializado quando o init com backend gravou o
# terraform.tfstate interno. Sem isso, destroy e plan não sabem onde está
# o state remoto.
tf_inicializado() {
  [ -f "$1/.terraform/terraform.tfstate" ]
}

# Inicializa usando o backend. Exige TF_BACKEND_BUCKET, a não ser que o
# diretório já esteja inicializado.
tf_init() {
  local dir="$1" key="$2"
  if tf_inicializado "$dir"; then
    info "Já inicializado: $(basename "$dir")"
    return 0
  fi
  [ -n "${TF_BACKEND_BUCKET:-}" ] || morrer \
    "TF_BACKEND_BUCKET não definido e '$(basename "$dir")' não está inicializado.
     Use:  export TF_BACKEND_BUCKET=<seu-bucket>"

  info "terraform init em $(basename "$dir") (key: $key)"
  ( cd "$dir" && terraform init -input=false \
      -backend-config="bucket=$TF_BACKEND_BUCKET" \
      -backend-config="key=$key" \
      -backend-config="region=${REGIAO:-us-east-1}" >/dev/null ) \
    || morrer "Falha no terraform init de $dir"
}

# O state tem recursos? Usado para decidir se vale destruir a camada.
tf_tem_recursos() {
  local dir="$1" n
  n=$( cd "$dir" && terraform state list 2>/dev/null | wc -l | tr -d ' ' )
  [ "${n:-0}" -gt 0 ]
}

# --- Leitura de configuração ---------------------------------------------
# Lê um valor string do terraform.tfvars. Evita depender de jq ou de
# `terraform output`, que exigiriam state inicializado.
ler_tfvar() {
  local dir="$1" nome="$2" arquivo="$1/terraform.tfvars"
  [ -f "$arquivo" ] || return 1
  grep -E "^[[:space:]]*${nome}[[:space:]]*=" "$arquivo" \
    | head -1 \
    | sed -E 's/.*=[[:space:]]*"([^"]*)".*/\1/'
}

# --- Kubernetes -----------------------------------------------------------
cluster_existe() {
  aws eks describe-cluster --name "$1" --region "${REGIAO:-us-east-1}" >/dev/null 2>&1
}

kubectl_conectado() {
  kubectl cluster-info >/dev/null 2>&1
}
