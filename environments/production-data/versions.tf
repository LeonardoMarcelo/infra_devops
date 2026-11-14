# ---------------------------------------------------------------------------
# REQUISITOS DE VERSÃO — RAIZ
# ---------------------------------------------------------------------------
# Versões FIXAS, como em toda raiz. Ver environments/production/versions.tf.
# ---------------------------------------------------------------------------

terraform {
  required_version = "~> 1.17"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.73.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.7.2"
    }
  }
}
