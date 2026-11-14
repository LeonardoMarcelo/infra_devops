# ---------------------------------------------------------------------------
# PROVIDERS E LEITURA DA CAMADA BASE
# ---------------------------------------------------------------------------

provider "aws" {
  region = var.aws_region

  # Nenhum recurso escapa sem tag, nem os criados indiretamente.
  default_tags {
    tags = var.project_tags
  }
}

# ===========================================================================
# Leitura da camada base (VPC e cluster)
# ===========================================================================
# `terraform_remote_state` lê as SAÍDAS de outro state — não o state inteiro.
# É o contrato entre camadas: a base publica vpc_id, subnets e o security
# group dos nós; esta camada consome. Nenhuma das duas conhece a outra por
# dentro.
data "terraform_remote_state" "base" {
  backend = "s3"

  config = {
    bucket = var.state_bucket
    key    = var.state_key_base
    region = var.aws_region
  }
}
