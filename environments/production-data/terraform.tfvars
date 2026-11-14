# ---------------------------------------------------------------------------
# CONFIGURAÇÃO DA CAMADA DE DADOS
# ---------------------------------------------------------------------------
# Declarar um banco aqui cria o banco E o coloca no monitoramento. Nenhum
# módulo precisa ser alterado.
#
# A credencial NUNCA entra neste arquivo: o módulo gera a senha e guarda no
# AWS Secrets Manager.
# ---------------------------------------------------------------------------

aws_region  = "us-east-1"
name_prefix = "live"

project_tags = {
  Project     = "live"
  Environment = "producao"
  ManagedBy   = "terraform"
  Repository  = "infra_devops"
  Layer       = "data"
}

# Key do state da camada base, para ler VPC, subnets e o security group dos
# nós. O bucket vem de TF_VAR_state_bucket.
state_key_base = "producao/infra.tfstate"

# Libera automaticamente o acesso a partir dos nós do cluster.
allow_from_cluster_nodes = true

# Janela de recuperação dos segredos. 0 para ambiente de estudo, onde criar e
# destruir o mesmo nome repetidamente esbarraria em "segredo agendado para
# exclusão". Em produção, 7 ou mais.
secret_recovery_days = 0

# ---------------------------------------------------------------------------
# BANCOS
# ---------------------------------------------------------------------------
# Vazio de propósito: nada é criado até você declarar. Descomente o que
# precisar.
#
# CUSTO: cada banco é cobrado por hora, somado ao EKS. Estimativas em
# us-east-1, on-demand:
#
#   mysql/postgres  db.t3.micro   ~US$ 0,017/h  (~US$ 12/mês)
#   oracle          db.t3.small   ~US$ 0,047/h  (~US$ 34/mês)  + licença
#   mongodb         db.t3.medium  ~US$ 0,078/h  (~US$ 57/mês)
#   elasticsearch   t3.small      ~US$ 0,036/h  (~US$ 26/mês)
#
# Mais armazenamento gp3 a ~US$ 0,08/GB-mês.
# ---------------------------------------------------------------------------

databases = {}

# databases = {
#   # --- MySQL (ex.: o backend do website_project) --------------------------
#   pedidos = {
#     engine     = "mysql"
#     storage_gb = 20
#     username   = "admin"
#   }
#
#   # --- PostgreSQL ---------------------------------------------------------
#   analytics = {
#     engine                = "postgres"
#     storage_gb            = 20
#     backup_retention_days = 7
#   }
#
#   # --- MongoDB (Amazon DocumentDB) ----------------------------------------
#   # Fala o protocolo do MongoDB, mas NÃO é MongoDB: compatibilidade
#   # parcial. Ver o README do módulo antes de adotar.
#   catalogo = {
#     engine         = "mongodb"
#     instance_count = 1
#   }
#
#   # --- Elasticsearch (Amazon OpenSearch) ----------------------------------
#   busca = {
#     engine     = "elasticsearch"
#     storage_gb = 10
#   }
#
#   # --- Oracle -------------------------------------------------------------
#   # db.t3.micro não suporta Oracle; o mínimo é db.t3.small.
#   # Sem exporter Prometheus: aparece em `monitoring_unsupported` e deve ser
#   # monitorado via CloudWatch.
#   legado = {
#     engine         = "oracle"
#     instance_class = "db.t3.small"
#     storage_gb     = 20
#   }
# }
