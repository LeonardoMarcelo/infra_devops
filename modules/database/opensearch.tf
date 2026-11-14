# ---------------------------------------------------------------------------
# OPENSEARCH — elasticsearch, opensearch
# ---------------------------------------------------------------------------
# O Amazon OpenSearch Service é o sucessor do Amazon Elasticsearch Service.
# Domínios novos nascem OpenSearch; "elasticsearch" aqui é apelido para a
# mesma coisa, mantido porque é como as pessoas pedem.
#
# Três camadas de proteção, todas ligadas:
#   1. domínio dentro da VPC, alcançável só por security group
#   2. criptografia em repouso e entre nós, HTTPS obrigatório
#   3. fine-grained access control com usuário mestre interno
# ---------------------------------------------------------------------------

locals {
  # Zone awareness distribui os nós entre AZs. A AWS exige número par de nós
  # e o mesmo número de subnets. Com 1 nó, precisa estar desligada.
  os_cfg = {
    for k, v in local.os : k => {
      multi_az = v.instance_count > 1
      # 1 nó -> 1 subnet. 2+ nós -> 2 subnets, uma por AZ.
      subnets = v.instance_count > 1 ? slice(var.subnet_ids, 0, 2) : [var.subnet_ids[0]]
      # Arredonda para par: zone awareness com número ímpar é rejeitado.
      nos = v.instance_count > 1 ? (
        v.instance_count % 2 == 0 ? v.instance_count : v.instance_count + 1
      ) : 1
    }
  }
}

resource "aws_opensearch_domain" "os" {
  for_each = local.os

  domain_name    = local.cfg[each.key].identificador
  engine_version = each.value.engine_version

  cluster_config {
    instance_type  = local.cfg[each.key].classe
    instance_count = local.os_cfg[each.key].nos

    zone_awareness_enabled = local.os_cfg[each.key].multi_az

    dynamic "zone_awareness_config" {
      for_each = local.os_cfg[each.key].multi_az ? [1] : []
      content {
        availability_zone_count = 2
      }
    }
  }

  ebs_options {
    ebs_enabled = true
    volume_type = "gp3"
    volume_size = each.value.storage_gb
  }

  # Dentro da VPC: o domínio não recebe endereço público.
  vpc_options {
    subnet_ids         = local.os_cfg[each.key].subnets
    security_group_ids = [aws_security_group.banco[each.key].id]
  }

  encrypt_at_rest {
    enabled = true
  }

  node_to_node_encryption {
    enabled = true
  }

  domain_endpoint_options {
    enforce_https       = true
    tls_security_policy = "Policy-Min-TLS-1-2-2019-07"
  }

  # Fine-grained access control: autenticação por usuário, além da rede.
  # Exige as três opções de criptografia acima — a AWS rejeita sem elas.
  advanced_security_options {
    enabled                        = true
    internal_user_database_enabled = true

    master_user_options {
      master_user_name     = local.cfg[each.key].usuario
      master_user_password = random_password.mestre[each.key].result
    }
  }

  # Política permissiva de propósito: num domínio em VPC, quem controla o
  # acesso é o security group mais o fine-grained access control acima.
  # Restringir aqui também costuma só gerar erro difícil de diagnosticar.
  access_policies = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "*" }
      Action    = "es:*"
      Resource  = "arn:aws:es:${data.aws_region.atual.region}:${data.aws_caller_identity.atual.account_id}:domain/${local.cfg[each.key].identificador}/*"
    }]
  })

  tags = local.cfg[each.key].tags

  lifecycle {
    ignore_changes = [advanced_security_options[0].master_user_options]
  }
}
