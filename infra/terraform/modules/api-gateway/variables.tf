variable "name_prefix" {
  type = string
}

variable "lambda_function_name" {
  description = "Nome da função Lambda de autenticação por CPF (para permitir a invocação pelo API Gateway)."
  type        = string
}

variable "lambda_invoke_arn" {
  description = "invoke_arn da função Lambda de autenticação por CPF."
  type        = string
}

variable "app_backend_url" {
  description = <<-EOT
    URL pública do backend da aplicação principal (ex.: http://<hostname-do-LB>),
    sem barra final. Só é conhecida depois que k8s/base/app-service-external.yaml
    é aplicado e o Load Balancer termina de ser provisionado — obtenha com:
    kubectl -n oficina get svc oficina-app-lb -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
  EOT
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
