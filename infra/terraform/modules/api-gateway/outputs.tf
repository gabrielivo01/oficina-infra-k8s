output "api_endpoint" {
  value       = aws_apigatewayv2_stage.default.invoke_url
  description = "URL pública do API Gateway. POST {api_endpoint}/auth/cpf autentica por CPF; as demais rotas fazem proxy para a aplicação principal."
}
