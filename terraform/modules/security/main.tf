###############################################################################
# modules/security/main.tf — Security Groups for App + Observability
#
# Cross-SG rules use standalone aws_security_group_rule resources to
# avoid the circular dependency (app → monitoring, monitoring → app).
###############################################################################

# -----------------------------------------------------------------------
#  App Instance Security Group
# -----------------------------------------------------------------------
resource "aws_security_group" "app" {
  name        = "${var.project_name}-app-sg"
  description = "Security group for the voting app instance"
  vpc_id      = var.vpc_id

  # SSH
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  # Dynamic public app ports (frontend, backend)
  dynamic "ingress" {
    for_each = var.app_ports
    content {
      description = ingress.value.description
      from_port   = ingress.value.port
      to_port     = ingress.value.port
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    { Name = "${var.project_name}-app-sg" },
    var.extra_tags,
  )
}

# -----------------------------------------------------------------------
#  Monitoring / Observability Instance Security Group
# -----------------------------------------------------------------------
resource "aws_security_group" "monitoring" {
  name        = "${var.project_name}-monitoring-sg"
  description = "Security group for the observability instance"
  vpc_id      = var.vpc_id

  # SSH
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  # Dynamic public monitoring ports (Prometheus, Grafana, Jaeger)
  dynamic "ingress" {
    for_each = var.monitoring_ports
    content {
      description = ingress.value.description
      from_port   = ingress.value.port
      to_port     = ingress.value.port
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    { Name = "${var.project_name}-monitoring-sg" },
    var.extra_tags,
  )
}

# -----------------------------------------------------------------------
#  Cross-SG rules (standalone to break circular dependency)
#  monitoring → app: Prometheus scrapes exporters / app metrics
#  app → monitoring: App sends OTLP traces to Jaeger
# -----------------------------------------------------------------------

# Allow monitoring SG to scrape Node Exporter on app
resource "aws_security_group_rule" "app_node_exporter_from_monitoring" {
  type                     = "ingress"
  description              = "Node Exporter (Prometheus scrape)"
  from_port                = 9100
  to_port                  = 9100
  protocol                 = "tcp"
  security_group_id        = aws_security_group.app.id
  source_security_group_id = aws_security_group.monitoring.id
}

# Allow monitoring SG to scrape Redis Exporter on app
resource "aws_security_group_rule" "app_redis_exporter_from_monitoring" {
  type                     = "ingress"
  description              = "Redis Exporter (Prometheus scrape)"
  from_port                = 9121
  to_port                  = 9121
  protocol                 = "tcp"
  security_group_id        = aws_security_group.app.id
  source_security_group_id = aws_security_group.monitoring.id
}

# Allow monitoring SG to scrape Backend /metrics on app
resource "aws_security_group_rule" "app_backend_metrics_from_monitoring" {
  type                     = "ingress"
  description              = "Backend /metrics (Prometheus scrape)"
  from_port                = 3001
  to_port                  = 3001
  protocol                 = "tcp"
  security_group_id        = aws_security_group.app.id
  source_security_group_id = aws_security_group.monitoring.id
}

# Allow monitoring SG to scrape Frontend /metrics on app
resource "aws_security_group_rule" "app_frontend_metrics_from_monitoring" {
  type                     = "ingress"
  description              = "Frontend /metrics (Prometheus scrape)"
  from_port                = 3000
  to_port                  = 3000
  protocol                 = "tcp"
  security_group_id        = aws_security_group.app.id
  source_security_group_id = aws_security_group.monitoring.id
}

# Allow app SG to send OTLP HTTP traces to Jaeger on monitoring
resource "aws_security_group_rule" "monitoring_otlp_http_from_app" {
  type                     = "ingress"
  description              = "Jaeger OTLP HTTP (traces from app)"
  from_port                = 4318
  to_port                  = 4318
  protocol                 = "tcp"
  security_group_id        = aws_security_group.monitoring.id
  source_security_group_id = aws_security_group.app.id
}

# Allow app SG to send OTLP gRPC traces to Jaeger on monitoring
resource "aws_security_group_rule" "monitoring_otlp_grpc_from_app" {
  type                     = "ingress"
  description              = "Jaeger OTLP gRPC (traces from app)"
  from_port                = 4317
  to_port                  = 4317
  protocol                 = "tcp"
  security_group_id        = aws_security_group.monitoring.id
  source_security_group_id = aws_security_group.app.id
}
