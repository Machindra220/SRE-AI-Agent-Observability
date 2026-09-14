# NS records to set at BigRock registrar
output "nameserver" {
  description = "NS record to configure at Bigrock registrar"
  value = aws_route53_zone.main.name_servers
}

# Hosted zone ID — useful for adding more records later
output "hosted_zone_id" {
  description = "Route 53 hosted zone ID"
  value = aws_route53_zone.main.zone_id
}

# Dynamically resolved ELB hostname
output "elb_hostname" {
  description = "ELB hostname from var.elb_hostname (update after infra-up)"
  value = var.elb_hostname
}

# Full subdomain URL
output "app_url" {
  description = "Application URL"
  value = "http://${var.subdomain}.${var.domain_name}/api/health"
}
