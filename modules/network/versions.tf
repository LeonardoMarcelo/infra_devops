# ---------------------------------------------------------------------------
# REQUISITOS DE VERSÃO — MÓDULO
# ---------------------------------------------------------------------------
# Módulos declaram FAIXAS de versão (>=, ~>), nunca versões exatas.
# Quem fixa a versão exata é a raiz (environments/*). Se um módulo fixasse
# "6.73.0" e outro "6.72.0", não existiria resolução possível e o projeto
# simplesmente não daria init.
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
