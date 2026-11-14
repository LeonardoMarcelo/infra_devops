# ---------------------------------------------------------------------------
# DOCUMENTDB — mongodb
# ---------------------------------------------------------------------------
# O Amazon DocumentDB fala o protocolo do MongoDB, mas NÃO é MongoDB: é um
# motor próprio da AWS com compatibilidade parcial. Agregações recentes,
# transações entre coleções e alguns operadores podem não existir.
#
# Se a aplicação depende de recurso específico do MongoDB, o caminho é o
# MongoDB Atlas ou rodar MongoDB no próprio cluster — não este módulo.
# ---------------------------------------------------------------------------

resource "aws_docdb_cluster" "docdb" {
  for_each = local.docdb

  cluster_identifier = local.cfg[each.key].identificador
  engine             = "docdb"
  engine_version     = each.value.engine_version

  master_username = local.cfg[each.key].usuario
  master_password = random_password.mestre[each.key].result
  port            = local.cfg[each.key].porta

  db_subnet_group_name   = aws_docdb_subnet_group.docdb[0].name
  vpc_security_group_ids = [aws_security_group.banco[each.key].id]

  storage_encrypted = true

  backup_retention_period = each.value.backup_retention_days
  preferred_backup_window = "03:00-04:00"

  deletion_protection = each.value.deletion_protection
  skip_final_snapshot = each.value.skip_final_snapshot
  final_snapshot_identifier = (
    each.value.skip_final_snapshot
    ? null
    : "${local.cfg[each.key].identificador}-final"
  )

  # Log de auditoria e de query lenta. Sem isso não há como investigar
  # desempenho depois.
  enabled_cloudwatch_logs_exports = ["audit", "profiler"]

  apply_immediately = true

  tags = local.cfg[each.key].tags

  lifecycle {
    ignore_changes = [master_password]
  }
}

# ---------------------------------------------------------------------------
# Instâncias do cluster
# ---------------------------------------------------------------------------
# Um cluster DocumentDB sem instância não atende conexão nenhuma. O mapa
# abaixo achata "cluster x instância" numa chave única, porque `for_each` não
# aninha.
locals {
  docdb_instancias = merge([
    for k, v in local.docdb : {
      for i in range(v.instance_count) :
      "${k}-${i}" => {
        banco  = k
        indice = i
      }
    }
  ]...)
}

resource "aws_docdb_cluster_instance" "docdb" {
  for_each = local.docdb_instancias

  identifier         = "${local.cfg[each.value.banco].identificador}-${each.value.indice}"
  cluster_identifier = aws_docdb_cluster.docdb[each.value.banco].id
  instance_class     = local.cfg[each.value.banco].classe

  auto_minor_version_upgrade = true
  apply_immediately          = true

  tags = local.cfg[each.value.banco].tags
}
