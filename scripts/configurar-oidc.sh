#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# CONFIGURAR OIDC — GitHub Actions assume role na AWS, sem chave estática
# ---------------------------------------------------------------------------
# Com OIDC, o GitHub emite um token de curta duração a cada execução e a AWS
# o troca por credencial temporária. Não existe segredo guardado em lugar
# nenhum — e credencial que não existe não vaza.
#
# O que este script faz, de forma idempotente:
#   1. cria o provedor OIDC do GitHub na conta (se não existir)
#   2. cria a role com política de confiança restrita ao SEU repositório
#   3. anexa PowerUserAccess + IAMFullAccess
#   4. define a variável AWS_ROLE_ARN no repositório do GitHub
#
# Definir essa variável é o que ATIVA o OIDC na pipeline: os workflows já
# têm os dois caminhos, e escolhem por `if`. Nenhum YAML precisa mudar.
#
#   ./scripts/configurar-oidc.sh [--repo dono/repo] [--role nome] [--dry-run]
# ---------------------------------------------------------------------------
set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/comum.sh"

ROLE="github-actions-terraform"
REPO=""
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)    REPO="${2:-}"; shift 2 ;;
    --role)    ROLE="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help)
      printf '%s\n' "configurar-oidc.sh — troca chave estática por OIDC"
      printf '%s\n' "  ./scripts/configurar-oidc.sh [--repo dono/repo] [--role nome] [--dry-run]"
      exit 0 ;;
    *) morrer "Opção desconhecida: $1" ;;
  esac
done

exigir aws gh
aws_autenticado || morrer "Credenciais da AWS não configuradas."

# Descobre o repositório pelo remote, se não informado.
if [ -z "$REPO" ]; then
  REPO=$(git -C "$RAIZ" remote get-url origin 2>/dev/null \
          | sed -E 's#.*github\.com[:/]##; s#\.git$##')
fi
[ -n "$REPO" ] || morrer "Não foi possível descobrir o repositório. Use --repo dono/repo"

CONTA="$(conta_aws)"
PROVIDER_ARN="arn:aws:iam::${CONTA}:oidc-provider/token.actions.githubusercontent.com"
ROLE_ARN="arn:aws:iam::${CONTA}:role/${ROLE}"

titulo "Configurar OIDC"
info "Conta AWS:    $CONTA"
info "Repositório:  $REPO"
info "Role:         $ROLE"
[ "$DRY_RUN" -eq 1 ] && aviso "DRY RUN — nada será criado"

# ===========================================================================
# ETAPA 1 — Provedor OIDC
# ===========================================================================
passo "Etapa 1/4 — provedor OIDC do GitHub"

if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$PROVIDER_ARN" >/dev/null 2>&1; then
  ok "Provedor já existe"
elif [ "$DRY_RUN" -eq 1 ]; then
  info "criaria o provedor $PROVIDER_ARN"
else
  # A AWS não valida mais o thumbprint para este emissor, mas a API ainda
  # exige o parâmetro.
  if aws iam create-open-id-connect-provider \
      --url https://token.actions.githubusercontent.com \
      --client-id-list sts.amazonaws.com \
      --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 >/dev/null 2>&1; then
    ok "Provedor criado"
  else
    morrer "Falha ao criar o provedor OIDC. Se a mensagem citar 'service control policy', a conta ainda está no Free plan: faça o upgrade antes."
  fi
fi

# ===========================================================================
# ETAPA 2 — Role, com confiança restrita ao repositório
# ===========================================================================
passo "Etapa 2/4 — role $ROLE"

# A condição `sub` é a peça central. Sem ela, QUALQUER repositório do GitHub
# poderia assumir esta role. Com ela, só o seu — e só nestas referências.
#
# Um fork vira "repo:outro-dono/infra_devops:...", que não casa. E PR vindo
# de fork nem recebe permissão para emitir o token OIDC.
TRUST=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "${PROVIDER_ARN}" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
      },
      "StringLike": {
        "token.actions.githubusercontent.com:sub": [
          "repo:${REPO}:ref:refs/heads/main",
          "repo:${REPO}:ref:refs/heads/develop",
          "repo:${REPO}:pull_request",
          "repo:${REPO}:environment:production"
        ]
      }
    }
  }]
}
EOF
)

if [ "$DRY_RUN" -eq 1 ]; then
  info "política de confiança que seria aplicada:"
  printf '%s\n' "$TRUST" | sed 's/^/      /'
elif aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  info "Role já existe — atualizando a política de confiança"
  aws iam update-assume-role-policy --role-name "$ROLE" \
    --policy-document "$TRUST" >/dev/null \
    && ok "Confiança atualizada" || morrer "Falha ao atualizar a confiança"
else
  aws iam create-role --role-name "$ROLE" \
    --description "GitHub Actions OIDC para ${REPO}" \
    --assume-role-policy-document "$TRUST" >/dev/null \
    && ok "Role criada" || morrer "Falha ao criar a role"
fi

# ===========================================================================
# ETAPA 3 — Permissões
# ===========================================================================
passo "Etapa 3/4 — permissões"

# PowerUser + IAMFullAccess em vez de AdministratorAccess: o módulo EKS cria
# roles de IAM (por isso IAMFullAccess), mas a role NÃO ganha poder sobre
# faturamento, Organizations nem encerramento de conta. Com cartão
# cadastrado, essa diferença importa.
for POL in PowerUserAccess IAMFullAccess; do
  if [ "$DRY_RUN" -eq 1 ]; then
    info "anexaria $POL"
  else
    aws iam attach-role-policy --role-name "$ROLE" \
      --policy-arn "arn:aws:iam::aws:policy/$POL" >/dev/null 2>&1 \
      && ok "$POL anexada" || aviso "falha ao anexar $POL"
  fi
done

# ===========================================================================
# ETAPA 4 — Ativar na pipeline
# ===========================================================================
passo "Etapa 4/4 — variável AWS_ROLE_ARN no GitHub"

if [ "$DRY_RUN" -eq 1 ]; then
  info "definiria AWS_ROLE_ARN=$ROLE_ARN em $REPO"
else
  if gh variable set AWS_ROLE_ARN --body "$ROLE_ARN" --repo "$REPO" 2>/dev/null; then
    ok "Variável definida — o OIDC está ATIVO na pipeline"
  else
    aviso "Não foi possível definir a variável. Defina à mão:"
    info "  Settings > Secrets and variables > Actions > Variables"
    info "  AWS_ROLE_ARN = $ROLE_ARN"
  fi
fi

# ===========================================================================
echo
if [ "$DRY_RUN" -eq 1 ]; then
  info "Dry run concluído. Rode sem --dry-run para aplicar."
  exit 0
fi

printf '%s\n' "${C_VERD}${C_NEG}OIDC configurado.${C_OFF}"
echo
info "Role: $ROLE_ARN"
echo
aviso "Agora APAGUE os secrets de chave estática — eles deixaram de ser usados:"
info "  gh secret delete AWS_ACCESS_KEY_ID --repo $REPO"
info "  gh secret delete AWS_SECRET_ACCESS_KEY --repo $REPO"
echo
aviso "E desative a chave no IAM:"
info "  IAM > Users > <usuário> > Security credentials > Deactivate"
