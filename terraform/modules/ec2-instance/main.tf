# modules/ec2-instance/main.tf — Reusable EC2 instance resource

resource "aws_instance" "this" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  key_name               = var.key_name
  subnet_id              = var.subnet_id
  vpc_security_group_ids = var.security_group_ids
  iam_instance_profile   = var.iam_instance_profile != "" ? var.iam_instance_profile : null

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = var.root_volume_type
    delete_on_termination = true
    encrypted             = true
  }

  user_data = var.user_data != "" ? var.user_data : null

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2
    http_put_response_hop_limit = 2
  }

  tags = merge(
    {
      Name = var.instance_name
      Role = var.instance_role
    },
    var.extra_tags,
  )

  lifecycle {
    ignore_changes = [user_data] # Prevent destroy on userdata drift
  }
}
