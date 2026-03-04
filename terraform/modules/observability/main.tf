###############################################################################
# modules/observability/main.tf — Observability Stack: SG + EC2 + Cross-SG Rules
#
# This module is intentionally placed AFTER the app module in the dependency
# graph.  It receives the app security group ID and owns ALL cross-SG rules
# so neither module creates a circular dependency.
###############################################################################

# -----------------------------------------------------------------------
#  Monitoring Security Group
# -----------------------------------------------------------------------
resource "aws_security_group" "this" {
  name        = "${var.project_name}-monitoring-sg"
  description = "Security group for the observability instance"
  vpc_id      = var.vpc_id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

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
#  EC2 Instance
# -----------------------------------------------------------------------
module "instance" {
  source = "../ec2-instance"

  instance_name        = "${var.project_name}-observability"
  instance_role        = "observability"
  ami_id               = var.ami_id
  instance_type        = var.instance_type
  key_name             = var.key_name
  subnet_id            = var.subnet_id
  security_group_ids   = [aws_security_group.this.id]
  iam_instance_profile = var.iam_instance_profile
  root_volume_size     = var.root_volume_size
  project_name         = var.project_name

  user_data = templatefile("${path.module}/userdata.sh.tpl", {
    aws_region = var.aws_region
  })
}

# -----------------------------------------------------------------------
#  Cross-SG Rules — Prometheus scrapes app exporters + app metrics
#  (rules on the APP SG, source = this monitoring SG)
# -----------------------------------------------------------------------
resource "aws_security_group_rule" "app_node_exporter" {
  type                     = "ingress"
  description              = "Node Exporter (Prometheus scrape)"
  from_port                = 9100
  to_port                  = 9100
  protocol                 = "tcp"
  security_group_id        = var.app_security_group_id
  source_security_group_id = aws_security_group.this.id
}

resource "aws_security_group_rule" "app_redis_exporter" {
  type                     = "ingress"
  description              = "Redis Exporter (Prometheus scrape)"
  from_port                = 9121
  to_port                  = 9121
  protocol                 = "tcp"
  security_group_id        = var.app_security_group_id
  source_security_group_id = aws_security_group.this.id
}

resource "aws_security_group_rule" "app_backend_metrics" {
  type                     = "ingress"
  description              = "Backend /metrics (Prometheus scrape)"
  from_port                = 3001
  to_port                  = 3001
  protocol                 = "tcp"
  security_group_id        = var.app_security_group_id
  source_security_group_id = aws_security_group.this.id
}

resource "aws_security_group_rule" "app_frontend_metrics" {
  type                     = "ingress"
  description              = "Frontend /metrics (Prometheus scrape)"
  from_port                = 3000
  to_port                  = 3000
  protocol                 = "tcp"
  security_group_id        = var.app_security_group_id
  source_security_group_id = aws_security_group.this.id
}

# -----------------------------------------------------------------------
#  Cross-SG Rules — App sends OTLP traces to Jaeger
#  (rules on THIS monitoring SG, source = app SG)
# -----------------------------------------------------------------------
resource "aws_security_group_rule" "otlp_http_from_app" {
  type                     = "ingress"
  description              = "Jaeger OTLP HTTP (traces from app)"
  from_port                = 4318
  to_port                  = 4318
  protocol                 = "tcp"
  security_group_id        = aws_security_group.this.id
  source_security_group_id = var.app_security_group_id
}

resource "aws_security_group_rule" "otlp_grpc_from_app" {
  type                     = "ingress"
  description              = "Jaeger OTLP gRPC (traces from app)"
  from_port                = 4317
  to_port                  = 4317
  protocol                 = "tcp"
  security_group_id        = aws_security_group.this.id
  source_security_group_id = var.app_security_group_id
}
