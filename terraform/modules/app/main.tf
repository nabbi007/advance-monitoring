###############################################################################
# modules/app/main.tf — Voting App: Security Group + EC2 Instance
###############################################################################

# -----------------------------------------------------------------------
#  Security Group
# -----------------------------------------------------------------------
resource "aws_security_group" "this" {
  name        = "${var.project_name}-app-sg"
  description = "Security group for the voting app instance"
  vpc_id      = var.vpc_id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

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
#  EC2 Instance
# -----------------------------------------------------------------------
module "instance" {
  source = "../ec2-instance"

  instance_name        = "${var.project_name}-app"
  instance_role        = "app"
  ami_id               = var.ami_id
  instance_type        = var.instance_type
  key_name             = var.key_name
  subnet_id            = var.subnet_id
  security_group_ids   = [aws_security_group.this.id]
  iam_instance_profile = var.iam_instance_profile
  root_volume_size     = var.root_volume_size
  project_name         = var.project_name

  user_data = templatefile("${path.module}/userdata.sh.tpl", {
    monitoring_private_ip = var.monitoring_private_ip
    aws_region            = var.aws_region
  })
}
