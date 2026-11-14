# ---------------------------------------------------------------------------
# MÓDULO: DATABASE
# ---------------------------------------------------------------------------
# Um mapa de bancos, várias engines, três serviços da AWS por baixo.
#
# A saída `monitoring_targets` sai no formato exato que o módulo
# `observability` consome: é isso que torna a integração automática. Declarar
# um banco aqui faz o exporter dele aparecer no Prometheus sem nenhum passo
# manual.
# ---------------------------------------------------------------------------

data "aws_caller_identity" "atual" {}
data "aws_region" "atual" {}

# ===========================================================================
# ETAPA 1 — Classificação por família de serviço
# ===========================================================================
locals {
  engines_rds   = ["mysql", "postgres", "mariadb", "oracle"]
  engines_docdb = ["mongodb"]
  engines_os    = ["elasticsearch", "opensearch"]

  rds   = { for k, v in var.databases : k => v if contains(local.engines_rds, v.engine) }
  docdb = { for k, v in var.databases : k => v if contains(local.engines_docdb, v.engine) }
  os    = { for k, v in var.databases : k => v if contains(local.engines_os, v.engine) }

  # --- Padrões por engine ---------------------------------------------------
  # Nome do engine no RDS. "oracle" sozinho não existe: é preciso escolher a
  # edição, e a SE2 é a de licença incluída mais barata.
  engine_rds = {
    mysql    = "mysql"
    postgres = "postgres"
    mariadb  = "mariadb"
    oracle   = "oracle-se2"
  }

  porta_padrao = {
    mysql         = 3306
    mariadb       = 3306
    postgres      = 5432
    oracle        = 1521
    mongodb       = 27017
    elasticsearch = 443
    opensearch    = 443
  }

  # Oracle não roda em db.t3.micro; DocumentDB começa em db.t3.medium.
  classe_padrao = {
    mysql         = "db.t3.micro"
    mariadb       = "db.t3.micro"
    postgres      = "db.t3.micro"
    oracle        = "db.t3.small"
    mongodb       = "db.t3.medium"
    elasticsearch = "t3.small.search"
    opensearch    = "t3.small.search"
  }

  # Logs exportados para o CloudWatch. Valores válidos variam por engine.
  logs_padrao = {
    mysql    = ["error", "slowquery"]
    mariadb  = ["error", "slowquery"]
    postgres = ["postgresql"]
    oracle   = ["alert"]
  }

  # Resolução final, por banco.
  cfg = {
    for k, v in var.databases : k => {
      engine         = v.engine
      identificador  = "${var.name_prefix}-${k}"
      porta          = coalesce(v.port, local.porta_padrao[v.engine])
      classe         = coalesce(v.instance_class, local.classe_padrao[v.engine])
      tags           = merge(var.tags, v.extra_tags, { Database = k, Engine = v.engine })
      usuario        = v.username
      instance_count = v.instance_count
    }
  }
}

# ===========================================================================
# ETAPA 2 — Credenciais
# ===========================================================================
# Senha gerada pelo Terraform e guardada no Secrets Manager. Nunca escrita
# em tfvars nem passada por variável.
#
# Caracteres especiais limitados de propósito: "/", "@", '"' e espaço quebram
# string de conexão de RDS e de DocumentDB.
resource "random_password" "mestre" {
  for_each = var.databases

  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_secretsmanager_secret" "credenciais" {
  for_each = var.databases

  name                    = "${var.name_prefix}/database/${each.key}"
  description             = "Credenciais do banco ${each.key} (${each.value.engine})"
  recovery_window_in_days = var.secret_recovery_days

  tags = local.cfg[each.key].tags
}

resource "aws_secretsmanager_secret_version" "credenciais" {
  for_each = var.databases

  secret_id = aws_secretsmanager_secret.credenciais[each.key].id

  # JSON com tudo que uma aplicação ou um exporter precisa para conectar.
  secret_string = jsonencode({
    engine   = each.value.engine
    host     = local.hosts[each.key]
    port     = local.cfg[each.key].porta
    username = local.cfg[each.key].usuario
    password = random_password.mestre[each.key].result
    dbname   = coalesce(each.value.database_name, replace(each.key, "-", "_"))
  })
}

# ===========================================================================
# ETAPA 3 — Rede: quem pode conectar
# ===========================================================================
# Um security group por banco. O padrão é não permitir nada: o acesso é
# concedido explicitamente, em geral ao security group dos nós do cluster.
resource "aws_security_group" "banco" {
  for_each = var.databases

  name        = "${local.cfg[each.key].identificador}-sg"
  description = "Acesso ao banco ${each.key}"
  vpc_id      = var.vpc_id

  tags = merge(local.cfg[each.key].tags, { Name = "${local.cfg[each.key].identificador}-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

# Entrada a partir de outro security group — o caminho recomendado: não
# depende de faixa de IP e acompanha a troca de nós automaticamente.
resource "aws_vpc_security_group_ingress_rule" "de_security_group" {
  for_each = {
    for par in flatten([
      for k, v in var.databases : [
        for sg in v.allowed_security_group_ids : {
          chave = "${k}-${sg}"
          banco = k
          sg    = sg
        }
      ]
    ]) : par.chave => par
  }

  security_group_id            = aws_security_group.banco[each.value.banco].id
  referenced_security_group_id = each.value.sg
  from_port                    = local.cfg[each.value.banco].porta
  to_port                      = local.cfg[each.value.banco].porta
  ip_protocol                  = "tcp"
  description                  = "Acesso ao ${each.value.banco}"
}

# Entrada a partir de faixa de IP — use só quando não houver security group
# de origem (ex.: VPN, peering).
resource "aws_vpc_security_group_ingress_rule" "de_cidr" {
  for_each = {
    for par in flatten([
      for k, v in var.databases : [
        for cidr in v.allowed_cidr_blocks : {
          chave = "${k}-${replace(cidr, "/", "_")}"
          banco = k
          cidr  = cidr
        }
      ]
    ]) : par.chave => par
  }

  security_group_id = aws_security_group.banco[each.value.banco].id
  cidr_ipv4         = each.value.cidr
  from_port         = local.cfg[each.value.banco].porta
  to_port           = local.cfg[each.value.banco].porta
  ip_protocol       = "tcp"
  description       = "Acesso ao ${each.value.banco}"
}

# ===========================================================================
# ETAPA 4 — Grupos de subnet
# ===========================================================================
resource "aws_db_subnet_group" "rds" {
  count = length(local.rds) > 0 ? 1 : 0

  name        = "${var.name_prefix}-rds"
  description = "Subnets privadas para RDS"
  subnet_ids  = var.subnet_ids

  tags = var.tags
}

resource "aws_docdb_subnet_group" "docdb" {
  count = length(local.docdb) > 0 ? 1 : 0

  name        = "${var.name_prefix}-docdb"
  description = "Subnets privadas para DocumentDB"
  subnet_ids  = var.subnet_ids

  tags = var.tags
}

# ===========================================================================
# ETAPA 5 — Endereços, resolvidos depois da criação
# ===========================================================================
locals {
  hosts = merge(
    { for k, v in aws_db_instance.rds : k => v.address },
    { for k, v in aws_docdb_cluster.docdb : k => v.endpoint },
    { for k, v in aws_opensearch_domain.os : k => v.endpoint },
  )
}
