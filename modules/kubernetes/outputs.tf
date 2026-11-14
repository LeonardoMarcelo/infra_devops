# ---------------------------------------------------------------------------
# SAÍDAS DO MÓDULO DE KUBERNETES
# ---------------------------------------------------------------------------

output "cluster_name" {
  description = "Nome do cluster. Usado no comando de kubeconfig."
  value       = module.eks.cluster_name
}

output "cluster_arn" {
  description = "ARN do cluster."
  value       = module.eks.cluster_arn
}

output "cluster_endpoint" {
  description = "Endpoint HTTPS da API do cluster."
  value       = module.eks.cluster_endpoint
}

output "cluster_version" {
  description = "Versão do Kubernetes em execução no plano de controle."
  value       = module.eks.cluster_version
}

output "cluster_certificate_authority_data" {
  description = <<-EOT
    Certificado da CA do cluster, em base64.

    Marcado como `sensitive` para não ser impresso em log de pipeline. Não é
    segredo de autenticação, mas vazá-lo em log facilita ataque de
    personificação do endpoint.
  EOT
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "cluster_security_group_id" {
  description = "Security group gerenciado pelo EKS para o plano de controle."
  value       = module.eks.cluster_security_group_id
}

output "node_security_group_id" {
  description = "Security group dos nós. Alvo de regra para liberar acesso a banco, etc."
  value       = module.eks.node_security_group_id
}

output "oidc_provider_arn" {
  description = <<-EOT
    ARN do provedor OIDC do cluster.

    É a peça que habilita IRSA (IAM Roles for Service Accounts): dar
    permissão de AWS a um pod específico, em vez de dar permissão à role do
    nó inteiro — onde qualquer pod naquele nó herdaria o acesso.
  EOT
  value       = module.eks.oidc_provider_arn
}

output "cluster_oidc_issuer_url" {
  description = "URL do emissor OIDC do cluster."
  value       = module.eks.cluster_oidc_issuer_url
}
