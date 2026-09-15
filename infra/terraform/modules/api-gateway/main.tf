terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

resource "aws_apigatewayv2_api" "this" {
  name          = "${var.name_prefix}-api"
  protocol_type = "HTTP"

  tags = var.tags
}

# Rota pública de autenticação por CPF -> Lambda (ver infra/terraform/modules/auth-lambda)
resource "aws_apigatewayv2_integration" "auth_cpf" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_uri        = var.lambda_invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "auth_cpf" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "POST /auth/cpf"
  target    = "integrations/${aws_apigatewayv2_integration.auth_cpf.id}"
}

resource "aws_lambda_permission" "apigw_invoke" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = var.lambda_function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
}

# Demais rotas -> proxy HTTP para a aplicação principal em Kubernetes (oficina-app-lb).
# Observação: isso também torna /internal/** alcançável pelo Gateway; a proteção
# real desse caminho é o header X-Internal-Api-Key (InternalApiKeyFilter), não a
# rede. Endurecimento futuro: excluir /internal/** do proxy ou movê-lo para um
# VPC Link privado (ver documentacao/plano_implementacao.md, seção 3).
resource "aws_apigatewayv2_integration" "app_proxy" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "HTTP_PROXY"
  integration_method     = "ANY"
  integration_uri        = "${var.app_backend_url}/{proxy}"
  payload_format_version = "1.0"
}

resource "aws_apigatewayv2_route" "app_proxy" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "ANY /{proxy+}"
  target    = "integrations/${aws_apigatewayv2_integration.app_proxy.id}"
}

resource "aws_apigatewayv2_integration" "app_root" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "HTTP_PROXY"
  integration_method     = "ANY"
  integration_uri        = var.app_backend_url
  payload_format_version = "1.0"
}

resource "aws_apigatewayv2_route" "app_root" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "ANY /"
  target    = "integrations/${aws_apigatewayv2_integration.app_root.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true

  tags = var.tags
}
