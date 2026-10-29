# Let EC2 Auto Scaling handle capacity failures across AZs without changing regions.
data "aws_ami" "automatic" {
  count = local.automatic_placement ? 1 : 0
  filter {
    name   = "image-id"
    values = [local.ami_id]
  }
}

resource "aws_launch_template" "host" {
  count         = local.automatic_placement ? 1 : 0
  name_prefix   = "${var.name}-"
  image_id      = local.ami_id
  instance_type = var.instance_type
  user_data     = base64encode(local.bootstrap)
  iam_instance_profile {
    name = aws_iam_instance_profile.host.name
  }
  network_interfaces {
    device_index                = 0
    associate_public_ip_address = true
    delete_on_termination       = true
    security_groups             = [aws_security_group.host.id]
  }
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }
  block_device_mappings {
    device_name = data.aws_ami.automatic[0].root_device_name
    ebs {
      volume_type           = "gp3"
      volume_size           = var.root_volume_size
      encrypted             = true
      delete_on_termination = true
    }
  }
  tag_specifications {
    resource_type = "instance"
    tags          = { Name = var.name, Project = var.name, ManagedBy = "Terraform" }
  }
  tag_specifications {
    resource_type = "volume"
    tags          = { Name = var.name, Project = var.name, ManagedBy = "Terraform" }
  }
}

resource "aws_autoscaling_group" "host" {
  count                            = local.automatic_placement ? 1 : 0
  name_prefix                      = "${var.name}-"
  min_size                         = 1
  max_size                         = 1
  desired_capacity                 = 1
  vpc_zone_identifier              = concat([aws_subnet.lab.id], [for subnet in aws_subnet.candidate : subnet.id])
  health_check_type                = "EC2"
  wait_for_capacity_timeout        = "20m"
  ignore_failed_scaling_activities = true
  # This server holds application state. Do not rebalance or replace it for health.
  suspended_processes = ["AZRebalance", "ReplaceUnhealthy"]
  availability_zone_distribution {
    capacity_distribution_strategy = "balanced-best-effort"
  }
  launch_template {
    id      = aws_launch_template.host[0].id
    version = tostring(aws_launch_template.host[0].latest_version)
  }
  tag {
    key                 = "Name"
    value               = var.name
    propagate_at_launch = true
  }
  depends_on = [
    aws_route_table_association.lab,
    aws_route_table_association.candidate,
    aws_iam_role_policy_attachment.ssm,
    aws_iam_role_policy.artifacts,
    terraform_data.publish_images
  ]
}

# List matches per AZ so an empty group does not break refresh, plan, or destroy.
data "aws_instances" "automatic" {
  for_each             = local.automatic_placement ? toset(local.gpu_azs) : toset([])
  instance_state_names = ["running"]
  filter {
    name   = "tag:aws:autoscaling:groupName"
    values = [aws_autoscaling_group.host[0].name]
  }
  filter {
    name   = "availability-zone"
    values = [each.key]
  }
  depends_on = [aws_autoscaling_group.host]
}
