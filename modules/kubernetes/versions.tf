# ---------------------------------------------------------------------------
# REQUISITOS DE VERSÃO — MÓDULO
# ---------------------------------------------------------------------------
# Faixas, não versões exatas. Ver modules/network/versions.tf para o porquê.
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }
}
