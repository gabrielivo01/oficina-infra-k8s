terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "project_name" {
  description = "Project name used as a naming prefix."
  type        = string
  default     = "oficina"
}

variable "environment" {
  description = "Infrastructure environment name."
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "AWS region for the dev environment."
  type        = string
  default     = "us-east-1"
}

variable "lambda_function_name" {
  description = "Output lambda_function_name do repositorio oficina-auth-lambda (terraform output -raw lambda_function_name)."
  type        = string
}

variable "lambda_invoke_arn" {
  description = "Output lambda_invoke_arn do repositorio oficina-auth-lambda (terraform output -raw lambda_invoke_arn)."
  type        = string
}

variable "app_public_url" {
  description = <<-EOT
    URL publica da aplicacao principal (Load Balancer criado pelo repo
    oficina-app: k8s/base/app-service-external.yaml), sem barra final. So e
    conhecida apos aplicar o overlay k8s daquele repo; obtenha com:
    kubectl -n oficina get svc oficina-app-lb -o jsonpath='http://{.status.loadBalancer.ingress[0].hostname}'
    O default abaixo e um placeholder valido (para nao quebrar o primeiro
    apply, antes do oficina-app existir) e PRECISA ser substituido em seguida
    por um novo apply com o valor real.
  EOT
  type        = string
  default     = "https://example.invalid"
}

locals {
  name_prefix = "${var.project_name}-${var.environment}"
  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Repo        = "oficina-infra-k8s"
  }
}

module "eks_cluster" {
  source = "../../modules/eks-cluster"

  name_prefix             = local.name_prefix
  availability_zones      = ["${var.aws_region}a", "${var.aws_region}b"]
  public_subnet_cidrs     = ["10.0.1.0/24", "10.0.2.0/24"]
  node_group_min_size     = 1
  node_group_max_size     = 3
  node_group_desired_size = 2
  tags                    = local.tags
}

module "api_gateway" {
  source = "../../modules/api-gateway"

  name_prefix          = local.name_prefix
  lambda_function_name = var.lambda_function_name
  lambda_invoke_arn    = var.lambda_invoke_arn
  app_backend_url      = var.app_public_url
  tags                 = local.tags
}

output "cluster_name" {
  value       = module.eks_cluster.cluster_name
  description = "Provisioned EKS cluster name."
}

output "cluster_endpoint" {
  value       = module.eks_cluster.cluster_endpoint
  description = "Provisioned EKS cluster endpoint."
}

output "vpc_id" {
  value       = module.eks_cluster.vpc_id
  description = "VPC id (consumido pelo repo oficina-infra-db para provisionar o RDS na mesma VPC)."
}

output "subnet_ids" {
  value       = module.eks_cluster.subnet_ids
  description = "Subnet ids (consumido pelo repo oficina-infra-db)."
}

output "api_endpoint" {
  value       = module.api_gateway.api_endpoint
  description = "URL publica do API Gateway (POST {api_endpoint}/auth/cpf autentica por CPF; demais rotas fazem proxy para a aplicacao)."
}
