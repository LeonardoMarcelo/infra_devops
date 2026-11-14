# ---------------------------------------------------------------------------
# RDS — mysql, postgres, mariadb, oracle
# ---------------------------------------------------------------------------
# Um recurso serve às quatro engines: o que muda é a string de engine, a
# classe mínima de instância e a lista de logs exportáveis. Essa é a razão de
# `aws_db_instance` ser um só, e não quatro blocos quase iguais.
# ---------------------------------------------------------------------------

resource "aws_db_instance" "rds" {
  for_each = local.rds

  identifier     = local.cfg[each.key].identificador
  engine         = local.engine_rds[each.value.engine]
  engine_version = each.value.engine_version
  instance_class = local.cfg[each.key].classe

  # Oracle é cobrado com licença embutida; as demais engines não têm o campo.
  license_model = each.value.engine == "oracle" ? "license-included" : null

  # --- Armazenamento ---
  allocated_storage = each.value.storage_gb
  # gp3 entrega IOPS de base melhor que gp2 pelo mesmo preço.
  storage_type = "gp3"
  # Criptografia em repouso, sempre. Não há motivo para desligar.
  storage_encrypted = true

  # --- Acesso ---
  db_name  = coalesce(each.value.database_name, replace(each.key, "-", "_"))
  username = local.cfg[each.key].usuario
  password = random_password.mestre[each.key].result
  port     = local.cfg[each.key].porta

  db_subnet_group_name   = aws_db_subnet_group.rds[0].name
  vpc_security_group_ids = [aws_security_group.banco[each.key].id]
  # Nunca exposto na internet. O acesso entra pelo security group.
  publicly_accessible = false

  # --- Disponibilidade ---
  multi_az = each.value.multi_az

  # --- Backup ---
  backup_retention_period = each.value.backup_retention_days
  backup_window           = "03:00-04:00"
  maintenance_window      = "sun:04:30-sun:05:30"
  copy_tags_to_snapshot   = true

  # --- Proteção ---
  deletion_protection = each.value.deletion_protection
  skip_final_snapshot = each.value.skip_final_snapshot
  # Exigido quando skip_final_snapshot = false. Nulo no caso contrário, senão
  # a AWS reclama de parâmetro inesperado.
  final_snapshot_identifier = (
    each.value.skip_final_snapshot
    ? null
    : "${local.cfg[each.key].identificador}-final"
  )

  # --- Observabilidade ---
  enabled_cloudwatch_logs_exports = coalesce(
    each.value.cloudwatch_logs_exports,
    lookup(local.logs_padrao, each.value.engine, [])
  )
  performance_insights_enabled = each.value.performance_insights

  # --- Manutenção ---
  auto_minor_version_upgrade = true
  apply_immediately          = true

  tags = local.cfg[each.key].tags

  lifecycle {
    ignore_changes = [
      # A senha vive no Secrets Manager. Rotacioná-la por fora não deve
      # provocar diff eterno no plan.
      password,
    ]
  }
}
