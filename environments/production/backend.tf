# ---------------------------------------------------------------------------
# BACKEND DE ESTADO
# ---------------------------------------------------------------------------
# O state descreve tudo que existe na infraestrutura e contém valores
# sensíveis. Fica no S3, nunca no repositório.
#
# Esta é uma "configuração parcial" de propósito: bucket e key vêm por
# -backend-config na pipeline, a partir dos secrets. Assim o mesmo código
# serve a outra conta ou outro ambiente sem edição.
#
# Para apontar o projeto a outro backend (Azure Storage, GCS, Terraform
# Cloud), este é o único arquivo que muda. Ver a seção de adaptação no README.
# ---------------------------------------------------------------------------

terraform {
  backend "s3" {
    # bucket  -> via -backend-config (secret AWS_BUCKET_NAME)
    # key     -> via -backend-config (secret AWS_BUCKET_FILE)
    # region  -> via -backend-config

    # Criptografia do objeto de state em repouso.
    encrypt = true

    # Lock de estado nativo do S3 (Terraform >= 1.10).
    # Impede dois applies simultâneos corrompendo o state. Antes disso era
    # preciso uma tabela DynamoDB só para isso; hoje o próprio S3 resolve.
    use_lockfile = true
  }
}
