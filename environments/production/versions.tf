# ---------------------------------------------------------------------------
# REQUISITOS DE VERSÃO — RAIZ
# ---------------------------------------------------------------------------
# Aqui, ao contrário dos módulos, as versões são FIXAS.
#
# A raiz é o único lugar que pode fixar: é ela que gera o .terraform.lock.hcl.
# Fixar aqui garante que a sua máquina, a máquina do colega e o runner do
# GitHub Actions produzam exatamente o mesmo plano. "Funciona na minha
# máquina" em infraestrutura costuma ser diferença de versão de provider.
# ---------------------------------------------------------------------------

terraform {
  # A mesma versão instalada na pipeline (ver .github/workflows/terraform.yml).
  required_version = "~> 1.17"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.73.0"
    }
  }
}
