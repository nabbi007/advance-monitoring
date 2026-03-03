###############################################################################
# instances.tf — EC2 Instances via reusable module (App + Observability)
###############################################################################

# -----------------------------------------------------------------------
#  App Instance — runs voting-frontend, voting-backend, redis (Docker)
#                 + node_exporter, redis_exporter (systemd via Ansible)
# -----------------------------------------------------------------------
module "app_instance" {
  source = "./modules/ec2-instance"

  instance_name        = "${var.project_name}-app"
  instance_role        = "app"
  ami_id               = local.ami_id
  instance_type        = var.app_instance_type
  key_name             = var.key_name
  subnet_id            = aws_subnet.public.id
  security_group_ids   = [aws_security_group.app.id]
  iam_instance_profile = aws_iam_instance_profile.ec2_profile.name
  root_volume_size     = 30
  project_name         = var.project_name

  user_data = templatefile("${path.module}/userdata_app.sh.tpl", {
    monitoring_private_ip = "" # Resolved post-apply by Ansible
    aws_region            = var.aws_region
  })
}

# -----------------------------------------------------------------------
#  Observability Instance — Prometheus, Grafana (systemd via Ansible)
#                           + Jaeger (Docker via Ansible)
# -----------------------------------------------------------------------
module "observability_instance" {
  source = "./modules/ec2-instance"

  instance_name        = "${var.project_name}-observability"
  instance_role        = "observability"
  ami_id               = local.ami_id
  instance_type        = var.observability_instance_type
  key_name             = var.key_name
  subnet_id            = aws_subnet.public.id
  security_group_ids   = [aws_security_group.monitoring.id]
  iam_instance_profile = aws_iam_instance_profile.ec2_profile.name
  root_volume_size     = 30
  project_name         = var.project_name

  user_data = templatefile("${path.module}/userdata_observability.sh.tpl", {
    aws_region = var.aws_region
  })
}
