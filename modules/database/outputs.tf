# ---------------------------------------------------------------------------
# SAÍDAS DO MÓDULO DE BANCO DE DADOS
# ---------------------------------------------------------------------------

locals {
  # Engine do banco -> engine do exporter Prometheus.
  # O mysqld_exporter atende MariaDB; o elasticsearch_exporter atende
  # OpenSearch. Oracle não tem exporter mantido pela prometheus-community,
  # por isso fica de fora (ver `monitoring_unsupported`).
  exporter_por_engine = {
    mysql         = "mysql"
    mariadb       = "mysql"
    postgres      = "postgres"
    mongodb       = "mongodb"
    elasticsearch = "elasticsearch"
    opensearch    = "elasticsearch"
  }

  monitoraveis = {
    for k, v in var.databases : k => v
    if v.monitoring_enabled && contains(keys(local.exporter_por_engine), v.engine)
  }

  nao_monitoraveis = {
    for k, v in var.databases : k => v.engine
    if v.monitoring_enabled && !contains(keys(local.exporter_por_engine), v.engine)
  }
}

output "monitoring_targets" {
  description = <<-EOT
    Alvos de monitoramento, já no formato que o módulo `observability`
    consome em `database_targets`.

    É esta saída que torna a integração automática: a camada de
    observabilidade lê isto por `terraform_remote_state` e passa a coletar o
    banco sem nenhum passo manual.
  EOT
  value = {
    for k, v in local.monitoraveis : k => {
      engine      = local.exporter_por_engine[v.engine]
      host        = local.hosts[k]
      port        = local.cfg[k].porta
      username    = local.cfg[k].usuario
      database    = coalesce(v.database_name, replace(k, "-", "_"))
      secret_arn  = aws_secretsmanager_secret.credenciais[k].arn
      secret_name = aws_secretsmanager_secret.credenciais[k].name
    }
  }
}

output "monitoring_unsupported" {
  description = <<-EOT
    Bancos com monitoramento pedido, mas sem exporter disponível.

    Hoje é o caso do Oracle. O caminho para ele é o CloudWatch (métricas do
    RDS, sem exporter nem credencial de banco) — ver o README do módulo.
    Exposto em vez de ignorado em silêncio.
  EOT
  value       = local.nao_monitoraveis
}

output "endpoints" {
  description = "Endereço de cada banco, por nome."
  value       = local.hosts
}

output "ports" {
  description = "Porta de cada banco, por nome."
  value       = { for k, v in local.cfg : k => v.porta }
}

output "security_group_ids" {
  description = <<-EOT
    Security group de cada banco.

    Use para liberar acesso depois da criação, sem recriar o banco.
  EOT
  value       = { for k, v in aws_security_group.banco : k => v.id }
}

output "secret_arns" {
  description = <<-EOT
    ARN do segredo de cada banco no Secrets Manager.

    O segredo guarda um JSON com engine, host, port, username, password e
    dbname. É daqui que a aplicação deve ler a credencial — nunca de variável
    de ambiente escrita à mão.
  EOT
  value       = { for k, v in aws_secretsmanager_secret.credenciais : k => v.arn }
}

output "secret_names" {
  description = "Nome do segredo de cada banco no Secrets Manager."
  value       = { for k, v in aws_secretsmanager_secret.credenciais : k => v.name }
}

output "connection_commands" {
  description = "Comando de conexão de cada banco, para conferência manual."
  value = {
    for k, v in var.databases : k => (
      v.engine == "postgres" ? "psql -h ${local.hosts[k]} -p ${local.cfg[k].porta} -U ${local.cfg[k].usuario}" :
      contains(["mysql", "mariadb"], v.engine) ? "mysql -h ${local.hosts[k]} -P ${local.cfg[k].porta} -u ${local.cfg[k].usuario} -p" :
      v.engine == "mongodb" ? "mongosh \"mongodb://${local.cfg[k].usuario}@${local.hosts[k]}:${local.cfg[k].porta}/?tls=true\"" :
      v.engine == "oracle" ? "sqlplus ${local.cfg[k].usuario}@//${local.hosts[k]}:${local.cfg[k].porta}/${coalesce(v.database_name, replace(k, "-", "_"))}" :
      "curl -u ${local.cfg[k].usuario} https://${local.hosts[k]}"
    )
  }
}
