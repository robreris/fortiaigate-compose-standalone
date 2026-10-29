output "instance_id" {
  value = local.host_id
}

output "ami_id" {
  value = local.ami_id
}

output "availability_zone" {
  value = local.host_az
}

output "candidate_availability_zones" {
  description = "AZs used for placement within aws_region."
  value       = local.automatic_placement ? local.gpu_azs : [var.availability_zone]
}

output "autoscaling_group_name" {
  description = "Automatic placement group, or null when pinned to one AZ."
  value       = local.automatic_placement ? aws_autoscaling_group.host[0].name : null
}

output "aws_region" {
  value = var.aws_region
}

output "registry_path" {
  description = "Registry server/path to enter in the vendor wizard (no https://)."
  value       = local.registry_path
}

output "repository_urls" {
  value = local.repository_urls
}

output "session_command" {
  value = local.host_id == null ? null : "aws ssm start-session --region ${var.aws_region} --target ${local.host_id}"
}

output "webui_tunnel_command" {
  value = local.host_id == null ? null : "aws ssm start-session --region ${var.aws_region} --target ${local.host_id} --document-name AWS-StartPortForwardingSession --parameters '{\"portNumber\":[\"443\"],\"localPortNumber\":[\"8443\"]}'"
}

output "publisher_policy" {
  description = "ECR permissions for a separate workstation publisher; attach via your IAM administrator, not to the EC2 role."
  value = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["ecr:GetAuthorizationToken"], Resource = "*" },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:DescribeImages", "ecr:BatchGetImage"
        ]
        Resource = local.repository_arns
      }
    ]
  })
}
