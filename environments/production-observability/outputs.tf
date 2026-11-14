# ---------------------------------------------------------------------------
# SAÍDAS DA CAMADA DE OBSERVABILIDADE
# ---------------------------------------------------------------------------

output "namespace" {
  description = "Namespace do monitoramento."
  value       = module.observability.namespace
}

output "grafana_admin_password" {
  description = "Senha do admin do Grafana. Leia com `terraform output -raw grafana_admin_password`."
  value       = module.observability.grafana_admin_password
  sensitive   = true
}

output "grafana_port_forward_command" {
  description = "Abre o Grafana localmente, sem expor nada na internet."
  value       = module.observability.grafana_port_forward_command
}

output "prometheus_port_forward_command" {
  description = "Abre a interface do Prometheus localmente."
  value       = module.observability.prometheus_port_forward_command
}

output "monitored_apis" {
  description = "APIs instrumentadas registradas."
  value       = module.observability.monitored_apis
}

output "monitored_probes" {
  description = "Sondagens HTTP configuradas."
  value       = module.observability.monitored_probes
}

output "monitored_databases" {
  description = "Bancos com exporter instalado."
  value       = module.observability.monitored_databases
}
