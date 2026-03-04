###############################################################################
# main.tf — Root module: all resource and module declarations
###############################################################################

# -----------------------------------------------------------------------
#  AMI Lookup (skipped when var.ami_id is set — avoids ec2:DescribeImages
#  in restricted IAM environments like sandbox / DCE accounts)
# -----------------------------------------------------------------------
data "aws_ami" "ubuntu" {
  count       = var.ami_id == "" ? 1 : 0
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Current AWS account identity (used for ECR registry URL)
data "aws_caller_identity" "current" {}

locals {
  ami_id       = var.ami_id != "" ? var.ami_id : data.aws_ami.ubuntu[0].id
  account_id   = data.aws_caller_identity.current.account_id
  ecr_registry = "${local.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
}

# -----------------------------------------------------------------------
#  SSH Key Pair (RSA 4096-bit, named after the project)
#  Retrieve the private key after apply:
#    terraform output -raw ssh_private_key > ~/.ssh/deploy_key.pem
#    chmod 600 ~/.ssh/deploy_key.pem
# -----------------------------------------------------------------------
resource "tls_private_key" "deploy" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "deploy" {
  key_name   = "${var.project_name}-key"
  public_key = tls_private_key.deploy.public_key_openssh

  tags = { Name = "${var.project_name}-key" }
}

# -----------------------------------------------------------------------
#  IAM Role for EC2 — ECR pull + CloudWatch + SSM Session Manager
# -----------------------------------------------------------------------
resource "aws_iam_role" "ec2_role" {
  name = "${var.project_name}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Name = "${var.project_name}-ec2-role" }
}

resource "aws_iam_role_policy_attachment" "ecr_readonly" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_role_policy_attachment" "ssm_managed" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "${var.project_name}-ec2-profile"
  role = aws_iam_role.ec2_role.name
}

# -----------------------------------------------------------------------
#  VPC
# -----------------------------------------------------------------------
module "vpc" {
  source = "./modules/vpc"

  vpc_cidr           = var.vpc_cidr
  public_subnet_cidr = var.public_subnet_cidr
  availability_zone  = "${var.aws_region}a"
  project_name       = var.project_name
}

# -----------------------------------------------------------------------
#  App Instance (voting app + exporters)
# -----------------------------------------------------------------------
module "app" {
  source = "./modules/app"

  project_name         = var.project_name
  vpc_id               = module.vpc.vpc_id
  subnet_id            = module.vpc.public_subnet_id
  ami_id               = local.ami_id
  instance_type        = var.app_instance_type
  key_name             = aws_key_pair.deploy.key_name
  iam_instance_profile = aws_iam_instance_profile.ec2_profile.name
  allowed_ssh_cidr     = var.allowed_ssh_cidr
  aws_region           = var.aws_region
}

# -----------------------------------------------------------------------
#  Observability Instance (Prometheus, Grafana, Jaeger)
#  Takes app's SG id to create cross-SG ingress rules without a cycle
# -----------------------------------------------------------------------
module "observability" {
  source = "./modules/observability"

  project_name          = var.project_name
  vpc_id                = module.vpc.vpc_id
  subnet_id             = module.vpc.public_subnet_id
  ami_id                = local.ami_id
  instance_type         = var.observability_instance_type
  key_name              = aws_key_pair.deploy.key_name
  iam_instance_profile  = aws_iam_instance_profile.ec2_profile.name
  allowed_ssh_cidr      = var.allowed_ssh_cidr
  aws_region            = var.aws_region
  app_security_group_id = module.app.security_group_id
}

# -----------------------------------------------------------------------
#  ECR Repositories (voting-backend + voting-frontend)
# -----------------------------------------------------------------------
module "ecr" {
  source = "./modules/ecr"

  project_name     = var.project_name
  repository_names = ["voting-backend", "voting-frontend"]
  scan_on_push     = true
  max_image_count  = 10
}
