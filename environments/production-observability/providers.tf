# ---------------------------------------------------------------------------
# PROVIDERS
# ---------------------------------------------------------------------------
# O provider Helm precisa falar com a API do cluster. Os dados de conexão vêm
# de DATA SOURCES — leitura de um cluster que já existe — e não de recursos
# criados aqui. É essa separação que mantém `plan` e `destroy` funcionando.
# ---------------------------------------------------------------------------

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = var.project_tags
  }
}

# ===========================================================================
# Leitura do cluster provisionado por environments/production
# ===========================================================================
data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

# ===========================================================================
# Conexão com o cluster
# ===========================================================================
# ===========================================================================
# Leitura da camada de dados
# ===========================================================================
# É daqui que vem a integração automática: a camada de dados publica
# `monitoring_targets`, e esta camada passa a coletar cada banco declarado lá
# sem nenhum passo manual.
#
# `try` com padrão vazio: enquanto a camada de dados não existir, esta sobe
# normalmente, só sem bancos.
data "terraform_remote_state" "data" {
  count = var.descobrir_bancos ? 1 : 0

  backend = "s3"

  config = {
    bucket = var.state_bucket
    key    = var.state_key_data
    region = var.aws_region
  }
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks", "get-token",
      "--cluster-name", var.cluster_name,
      "--region", var.aws_region,
    ]
  }
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)

    # Autenticação por `exec`, não por token lido em data source.
    #
    # O token do EKS vale cerca de 15 minutos. A instalação da stack de
    # monitoramento pode passar disso, e um token expirado no meio do apply
    # falha de forma confusa. Com `exec`, o Terraform pede um token novo
    # sempre que precisa.
    #
    # Requisito: AWS CLI disponível na máquina que roda o Terraform. O runner
    # do GitHub Actions já tem.
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args = [
        "eks", "get-token",
        "--cluster-name", var.cluster_name,
        "--region", var.aws_region,
      ]
    }
  }
}
