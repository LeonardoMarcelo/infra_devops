# ---------------------------------------------------------------------------
# CONFIGURAÇÃO DO AMBIENTE DE PRODUÇÃO
# ---------------------------------------------------------------------------
# Carregado automaticamente pelo Terraform. É o único arquivo que muda entre
# ambientes — o código em modules/ e a composição em main.tf ficam iguais.
#
# Nada sensível entra aqui. Segredo vai para os secrets do GitHub Actions
# (credenciais, nome do bucket de state) ou para o AWS Secrets Manager.
# ---------------------------------------------------------------------------

# --- Conta e região -------------------------------------------------------

aws_region = "us-east-1"

project_tags = {
  Project     = "live"
  Environment = "producao"
  ManagedBy   = "terraform"
  Repository  = "infra_devops"
}

# --- Rede -----------------------------------------------------------------

vpc_name = "live-vpc"
vpc_cidr = "10.0.0.0/16"

# A ordem importa: private_subnet_cidrs[0] fica em availability_zones[0].
availability_zones   = ["us-east-1a", "us-east-1b", "us-east-1c"]
private_subnet_cidrs = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
public_subnet_cidrs  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

# Um NAT Gateway por AZ. Resiliente e mais caro (~US$ 32/mês cada, 3 AZs).
# Para ambiente de estudo ou desenvolvimento, troque para `true` e fique com
# um só.
single_nat_gateway = false

# Auditoria de rede.
enable_flow_logs         = true
flow_logs_retention_days = 30

# --- Cluster --------------------------------------------------------------

cluster_name = "live-eks"

# Verificado em 14/11/2026 com `aws eks describe-cluster-versions`:
#
#   1.37  suporte padrão até 30/11/2027
#   1.36  suporte padrão até 01/08/2027
#   1.35  suporte padrão até 26/03/2027   <- escolhida
#   1.34  suporte padrão até 01/12/2026   (expira em 2 semanas)
#   1.33 e anteriores: EXTENDED SUPPORT, cobrado à parte
#
# A 1.29 que estava aqui nem consta mais na lista da AWS — o apply falharia.
# A 1.35 equilibra maturidade e prazo: não é a mais nova, e tem suporte
# padrão por mais de 4 meses.
kubernetes_version = "1.35"

# Endpoint público ligado porque o apply roda em runner hospedado pelo
# GitHub, que está fora da VPC e precisa falar com a API do cluster.
# Restrinja os CIDRs se você tiver faixa de IP fixa. Ver o README para o
# caminho de fechar o endpoint por completo.
cluster_endpoint_public_access       = true
cluster_endpoint_public_access_cidrs = ["0.0.0.0/0"]

# Grupos de nós.
# min_size 2 atende o requisito de "no mínimo dois worker nodes";
# max_size 4 é o que dá elasticidade de verdade — com min = max o cluster
# não escala, apenas repõe nó que morreu.
node_groups = {
  default = {
    instance_types = ["t3.small"]
    min_size       = 2
    max_size       = 4
    desired_size   = 2
    capacity_type  = "ON_DEMAND"
  }
}

cluster_log_retention_days = 30

# `false` porque o desafio prevê um workflow de destroy. Em produção de
# verdade, `true` — e aí o destroy falha de propósito até alguém desligar
# esta proteção conscientemente.
cluster_deletion_protection = false

# Addons gerenciados. Vazio para não alterar cluster existente sem intenção.
# Ver modules/kubernetes/README.md para o conjunto recomendado.
cluster_addons = {}
