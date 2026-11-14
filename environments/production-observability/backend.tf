# ---------------------------------------------------------------------------
# BACKEND DE ESTADO
# ---------------------------------------------------------------------------
# STATE SEPARADO do ambiente de infraestrutura base, de propósito.
#
# Três razões:
#   1. Raio de dano. Um erro aqui não alcança a VPC nem o cluster.
#   2. Ciclo de vida. Dashboard e alerta mudam toda semana; VPC quase nunca.
#      Misturar os dois faria todo ajuste de alerta replanejar a rede inteira.
#   3. Dependência de provider. Os providers helm/kubernetes precisam de um
#      cluster que JÁ EXISTE. Configurar provider a partir de recurso criado
#      no mesmo apply quebra o primeiro apply e o destroy.
#
# Use uma `key` diferente da usada em environments/production.
# ---------------------------------------------------------------------------

terraform {
  backend "s3" {
    # bucket  -> via -backend-config (secret AWS_BUCKET_NAME)
    # key     -> via -backend-config (ex.: producao/observability.tfstate)
    # region  -> via -backend-config

    encrypt      = true
    use_lockfile = true
  }
}
