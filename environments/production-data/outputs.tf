# ---------------------------------------------------------------------------
# SAÍDAS DA CAMADA DE DADOS
# ---------------------------------------------------------------------------
# `monitoring_targets` é o contrato com a camada de observabilidade: ela lê
# esta saída por `terraform_remote_state` e passa a coletar os bancos sem
# nenhum passo manual.
# ---------------------------------------------------------------------------

output "monitoring_targets" {
  description = "Alvos prontos para a camada de observabilidade consumir."
  value       = module.databases.monitoring_targets
}

output "monitoring_unsupported" {
  description = "Bancos sem exporter disponível (hoje: Oracle). Use CloudWatch."
  value       = module.databases.monitoring_unsupported
}

output "endpoints" {
  description = "Endereço de cada banco."
  value       = module.databases.endpoints
}

output "ports" {
  description = "Porta de cada banco."
  value       = module.databases.ports
}

output "security_group_ids" {
  description = "Security group de cada banco, para liberar acesso depois."
  value       = module.databases.security_group_ids
}

output "secret_names" {
  description = <<-EOT
    Nome do segredo de cada banco no Secrets Manager.

    Para ler a credencial:
      aws secretsmanager get-secret-value --secret-id <nome> \
        --query SecretString --output text | jq
  EOT
  value       = module.databases.secret_names
}

output "secret_arns" {
  description = "ARN do segredo de cada banco. Use em política de IAM."
  value       = module.databases.secret_arns
}

output "connection_commands" {
  description = "Comando de conexão de cada banco, para conferência manual."
  value       = module.databases.connection_commands
}
