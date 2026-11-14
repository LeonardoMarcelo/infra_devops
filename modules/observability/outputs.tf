# ---------------------------------------------------------------------------
# SAÍDAS DO MÓDULO DE OBSERVABILIDADE
# ---------------------------------------------------------------------------

output "namespace" {
  description = "Namespace onde a stack foi instalada."
  value       = var.namespace
}

output "grafana_admin_password" {
  description = <<-EOT
    Senha do admin do Grafana.

    Sensível, e gravada no state. Leia com:
      terraform output -raw grafana_admin_password
  EOT
  value       = local.grafana_admin_password
  sensitive   = true
}

output "grafana_port_forward_command" {
  description = "Comando para abrir o Grafana sem expor nada na internet."
  value       = "kubectl -n ${var.namespace} port-forward svc/kube-prometheus-stack-grafana 3000:80"
}

output "prometheus_port_forward_command" {
  description = "Comando para abrir a interface do Prometheus."
  value       = "kubectl -n ${var.namespace} port-forward svc/kube-prometheus-stack-prometheus 9090:9090"
}

output "monitored_apis" {
  description = "APIs instrumentadas registradas como ServiceMonitor."
  value       = keys(var.api_targets)
}

output "monitored_probes" {
  description = "Sondagens HTTP configuradas via blackbox."
  value       = keys(var.http_probes)
}

output "monitored_databases" {
  description = "Bancos com exporter instalado, por engine."
  value       = { for name, db in var.database_targets : name => db.engine }
}
