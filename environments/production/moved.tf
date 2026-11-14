# ---------------------------------------------------------------------------
# REFATORAÇÃO SEM DESTRUIR RECURSOS
# ---------------------------------------------------------------------------
# O state do Terraform indexa recursos por ENDEREÇO. A modularização mudou
# esses endereços:
#
#   antes:  module.vpc.aws_vpc.this[0]
#   agora:  module.network.module.vpc.aws_vpc.this[0]
#
# Para o Terraform, endereço diferente é recurso diferente. Sem os blocos
# abaixo ele planejaria DESTRUIR a VPC e o cluster e CRIAR outros iguais.
#
# Os blocos `moved` dizem "é o mesmo recurso, só mudou de lugar". O Terraform
# reescreve o state durante o plan, sem tocar na infraestrutura. Confirme no
# plan que o resultado é "0 to add, 0 to destroy" na parte estrutural.
#
# QUANDO REMOVER ESTE ARQUIVO:
# depois que o apply da refatoração rodar com sucesso em todos os ambientes.
# Mantê-lo para sempre não quebra nada, mas vira ruído.
#
# SE VOCÊ AINDA NÃO TEM NADA PROVISIONADO:
# apague este arquivo. Ele só tem função sobre um state que já existe.
# ---------------------------------------------------------------------------

moved {
  from = module.vpc
  to   = module.network.module.vpc
}

moved {
  from = module.eks
  to   = module.kubernetes.module.eks
}
