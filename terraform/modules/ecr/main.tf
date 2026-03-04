###############################################################################
# modules/ecr/main.tf — ECR Repositories
#
# Creates ECR repositories for each service with lifecycle policies
# to keep costs under control and image scanning enabled.
###############################################################################

resource "aws_ecr_repository" "this" {
  for_each = toset(var.repository_names)

  name                 = "${var.project_name}-${each.value}"
  image_tag_mutability = var.image_tag_mutability
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = var.scan_on_push
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = merge(
    {
      Name    = "${var.project_name}-${each.value}"
      Service = each.value
    },
    var.extra_tags,
  )
}

# -----------------------------------------------------------------------
#  Lifecycle policy — keep only the N most recent images
# -----------------------------------------------------------------------
resource "aws_ecr_lifecycle_policy" "this" {
  for_each = toset(var.repository_names)

  repository = aws_ecr_repository.this[each.value].name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep only the last ${var.max_image_count} images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.max_image_count
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
