# ---------------------------------------------------------------------------
# REQUISITOS DE VERSÃO — MÓDULO
# ---------------------------------------------------------------------------
# Faixas, não versões exatas. Ver modules/network/versions.tf para o porquê.
#
# Este módulo NÃO declara `provider` nenhum: ele recebe os providers já
# configurados da raiz. Módulo que configura o próprio provider não pode ser
# reusado com outra autenticação, e quebra `terraform destroy`.
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.10"

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.12"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5"
    }
  }
}
