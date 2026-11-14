# ---------------------------------------------------------------------------
# PROVIDERS
# ---------------------------------------------------------------------------
# Credencial nunca aparece aqui. O provider resolve sozinho, na ordem:
# variável de ambiente -> ~/.aws/credentials -> role do runner/instância.
# Na pipeline, quem popula isso é o passo de configure-aws-credentials.
# ---------------------------------------------------------------------------

provider "aws" {
  region = var.aws_region

  # `default_tags` aplica estas tags a TODO recurso criado por este provider,
  # inclusive os que nenhum módulo tagueia explicitamente. É o que garante
  # rastreabilidade de custo sem depender de ninguém lembrar de tagear.
  default_tags {
    tags = var.project_tags
  }
}
