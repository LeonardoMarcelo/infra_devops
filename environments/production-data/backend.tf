# ---------------------------------------------------------------------------
# BACKEND DE ESTADO
# ---------------------------------------------------------------------------
# STATE SEPARADO — a camada de dados tem o ciclo de vida mais longo de todos.
#
# Cluster some e volta; o banco não. Separar o state é o que permite destruir
# a infraestrutura de computação sem encostar nos dados, e é o que impede que
# um destroy mal mirado leve o banco junto.
#
# Ordem de aplicação:
#   1. environments/production        VPC + cluster
#   2. environments/production-data   bancos (esta camada)
#   3. environments/production-observability
#
# Ordem de destruição: o inverso exato.
#
# Use uma `key` diferente das outras camadas.
#   ex.: producao/data.tfstate
# ---------------------------------------------------------------------------

terraform {
  backend "s3" {
    encrypt      = true
    use_lockfile = true
  }
}
