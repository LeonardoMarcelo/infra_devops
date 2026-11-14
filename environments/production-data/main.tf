# ---------------------------------------------------------------------------
# AMBIENTE: CAMADA DE DADOS DE PRODUÇÃO
# ---------------------------------------------------------------------------
# Só composição. Os bancos são declarados em terraform.tfvars.
# ---------------------------------------------------------------------------

# ===========================================================================
# ETAPA 1 — Acesso a partir do cluster
# ===========================================================================
# Acrescenta o security group dos nós à lista de origens permitidas de cada
# banco. Regra por security group, não por faixa de IP: acompanha a troca de
# nós sozinha, e um nó novo já nasce autorizado.
locals {
  node_sg = try(data.terraform_remote_state.base.outputs.node_security_group_id, null)

  databases = {
    for nome, db in var.databases : nome => merge(db, {
      allowed_security_group_ids = distinct(concat(
        db.allowed_security_group_ids,
        var.allow_from_cluster_nodes && local.node_sg != null ? [local.node_sg] : [],
      ))
    })
  }
}

# ===========================================================================
# ETAPA 2 — Bancos
# ===========================================================================
module "databases" {
  source = "../../modules/database"

  name_prefix = var.name_prefix

  # Sempre nas subnets privadas. Nenhum banco recebe endereço público.
  vpc_id     = data.terraform_remote_state.base.outputs.vpc_id
  subnet_ids = data.terraform_remote_state.base.outputs.private_subnet_ids

  databases            = local.databases
  secret_recovery_days = var.secret_recovery_days

  tags = var.project_tags
}
