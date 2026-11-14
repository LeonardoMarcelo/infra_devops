# ---------------------------------------------------------------------------
# SAÍDAS DO MÓDULO DE REDE
# ---------------------------------------------------------------------------
# Expõe só o que outro módulo precisa consumir. Repassar a saída inteira do
# módulo oficial vazaria sua interface para fora e tiraria a liberdade de
# trocar a implementação por baixo.
# ---------------------------------------------------------------------------

output "vpc_id" {
  description = "ID da VPC criada."
  value       = module.vpc.vpc_id
}

output "vpc_cidr_block" {
  description = "Bloco CIDR da VPC. Útil para montar regra de security group."
  value       = module.vpc.vpc_cidr_block
}

output "private_subnet_ids" {
  description = "IDs das subnets privadas. É aqui que ficam os nós do cluster."
  value       = module.vpc.private_subnets
}

output "public_subnet_ids" {
  description = "IDs das subnets públicas. É aqui que ficam os Load Balancers."
  value       = module.vpc.public_subnets
}

output "azs" {
  description = "Zonas de disponibilidade efetivamente usadas."
  value       = module.vpc.azs
}

output "nat_public_ips" {
  description = <<-EOT
    IPs públicos dos NAT Gateways.

    São os IPs de origem de todo tráfego que sai das subnets privadas: é esta
    a lista a informar quando um terceiro pedir allowlist de IP.
  EOT
  value       = module.vpc.nat_public_ips
}
