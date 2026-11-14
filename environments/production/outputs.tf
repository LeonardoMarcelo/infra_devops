# ---------------------------------------------------------------------------
# SAÍDAS DO AMBIENTE
# ---------------------------------------------------------------------------
# Aparecem ao fim do apply e ficam consultáveis com `terraform output`.
# Servem de ponte para quem vai usar o cluster depois.
# ---------------------------------------------------------------------------

output "cluster_name" {
  description = "Nome do cluster EKS."
  value       = module.kubernetes.cluster_name
}

output "cluster_endpoint" {
  description = "Endpoint da API do cluster."
  value       = module.kubernetes.cluster_endpoint
}

output "cluster_version" {
  description = "Versão do Kubernetes em execução."
  value       = module.kubernetes.cluster_version
}

output "kubeconfig_command" {
  description = "Comando pronto para configurar o kubectl nesta máquina."
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.kubernetes.cluster_name}"
}

output "vpc_id" {
  description = "ID da VPC."
  value       = module.network.vpc_id
}

output "private_subnet_ids" {
  description = "Subnets privadas, onde ficam os nós."
  value       = module.network.private_subnet_ids
}

output "nat_public_ips" {
  description = <<-EOT
    IPs de saída do cluster.

    São estes os IPs a informar quando um fornecedor pedir allowlist.
  EOT
  value       = module.network.nat_public_ips
}

output "oidc_provider_arn" {
  description = "ARN do provedor OIDC, necessário para configurar IRSA."
  value       = module.kubernetes.oidc_provider_arn
}

output "node_security_group_id" {
  description = <<-EOT
    Security group dos nós do cluster.

    É este o valor que a camada de dados usa para liberar o acesso aos
    bancos: a regra fica "quem está neste security group pode conectar",
    sem depender de faixa de IP e acompanhando a troca de nós.
  EOT
  value       = module.kubernetes.node_security_group_id
}
