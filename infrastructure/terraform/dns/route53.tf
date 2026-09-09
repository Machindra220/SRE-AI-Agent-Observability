# Manages Route 53 hosted zone and CNAME record.
# CNAME value is fetched dynamically from the live Kubernetes
# LoadBalancer service — no hardcoded ELB hostnames.
# Run terraform apply after every infra-up.sh to sync CNAME.
# ─────────────────────────────────────────────────────────────

# ── Fetch LoadBalancer hostname from live Kubernetes service ──
# This data source reads the actual ELB hostname assigned by AWS
# to the Kubernetes LoadBalancer service after deployment.
# ----------------------------

# data "kubernetes_service" "app" {
#   metadata {
#     name = var.k8s_service_name
#     namespace = var.k8s_namespace
#   }
# }


# ── Hosted Zone ───────────────────────────────────────────────
# Public hosted zone for machindra.online.
# NS records from this zone must be set at BigRock registrar.
# NEVER destroy this resource — deletion forces BigRock NS update.

resource "aws_route53_zone" "main" { 
    name = var.domain_name
    comment = "Managed by Terraform"

    tags = {
        Project = "SRE-Observability"
        ManagedBy = "terraform"
    } 
}


# ── CNAME Record ──────────────────────────────────────────────
# Routes sre.machindra.online → EKS LoadBalancer hostname.
# ELB hostname is fetched dynamically from the Kubernetes service
# — no manual update needed after infra-up.sh.

resource "aws_route53_record" "sre_cname" {
  zone_id = aws_route53_zone.main.zone_id
  name = "${var.subdomain}.${var.domain_name}"
  type = "CNAME"
  ttl = 300
  # Dynamically resolved from live Kubernetes LoadBalancer service
  records = [data.kubernetes_service.app.status.0.load_balancer.0.ingress.0.hostname]
}