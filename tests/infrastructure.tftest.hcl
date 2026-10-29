# Keep tests independent of a developer's local terraform.tfvars.
variables {
  aws_region            = "us-west-2"
  availability_zone     = "us-west-2a"
  allowed_https_ip      = ""
  instance_type         = "g6e.2xlarge"
  ami_id                = null
  name                  = "fortiaigate-lab"
  root_volume_size      = 300
  existing_ecr_registry = ""
  existing_s3_bucket    = ""
  fortiaigate_version   = "8.0.2"
  fortiaigate_build     = "0055"
  utility_archive       = "tests/fixtures/utility.txt"
}

mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_ssm_parameter" {
    defaults = { value = "ami-0123456789abcdef0" }
  }
  mock_data "aws_ec2_instance_type_offerings" {
    defaults = { locations = ["us-west-2b", "us-west-2a"] }
  }
  mock_data "aws_availability_zones" {
    defaults = { names = ["us-west-2a", "us-west-2b", "us-west-2c"] }
  }
  mock_data "aws_ami" {
    defaults = { root_device_name = "/dev/sda1" }
  }
  mock_data "aws_instances" {
    defaults = { ids = [] }
  }
  mock_resource "aws_ecr_repository" {
    defaults = {
      arn            = "arn:aws:ecr:us-west-2:123456789012:repository/fortiaigate-lab/api"
      repository_url = "123456789012.dkr.ecr.us-west-2.amazonaws.com/fortiaigate-lab/api"
    }
  }
  mock_resource "aws_launch_template" {
    defaults = {
      id             = "lt-0123456789abcdef0"
      latest_version = 1
    }
  }
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::fortiaigate-lab-utility-test" }
  }
  mock_resource "aws_s3_object" {
    defaults = { arn = "arn:aws:s3:::fortiaigate-lab-utility-test/cli/test.tar.gz" }
  }
}

run "secure_gpu_host" {
  command = apply
  # Apply tests always reuse ECR: terraform_data provisioners run even with an override.
  variables {
    existing_ecr_registry = "123456789012.dkr.ecr.us-west-2.amazonaws.com/fortiaigate-lab"
  }
  assert {
    condition     = length(aws_security_group.host.ingress) == 0
    error_message = "The host must have no inbound security-group rules."
  }
  assert {
    condition     = aws_instance.host[0].metadata_options[0].http_tokens == "required" && aws_instance.host[0].metadata_options[0].http_put_response_hop_limit == 1
    error_message = "Require IMDSv2 and prevent bridge containers from accessing instance credentials."
  }
  assert {
    condition     = aws_instance.host[0].root_block_device[0].encrypted && aws_instance.host[0].root_block_device[0].volume_size >= 200
    error_message = "Docker and deployment state require an encrypted EBS disk with room for images."
  }
  assert {
    condition     = aws_subnet.lab.availability_zone == "us-west-2a" && aws_instance.host[0].instance_type == "g6e.2xlarge"
    error_message = "Choose an offered AZ and the smallest G6e meeting GPU host requirements."
  }
  assert {
    condition     = !strcontains(aws_iam_role_policy.artifacts.policy, "ecr:PutImage") && !strcontains(aws_iam_role_policy.artifacts.policy, "s3:PutObject")
    error_message = "The host must not be granted artifact upload permissions."
  }
  assert {
    condition     = strcontains(aws_instance.host[0].user_data, "config['data-root'] = '/var/lib/docker'")
    error_message = "Keep application data on persistent EBS instead of instance-store NVMe."
  }
  assert {
    condition     = length(aws_autoscaling_group.host) == 0 && length(aws_subnet.candidate) == 0 && length(output.candidate_availability_zones) == 1 && output.candidate_availability_zones[0] == "us-west-2a"
    error_message = "A pinned AZ must retain the standalone instance and single subnet."
  }
}

run "allow_https_from_one_ip" {
  command = apply
  variables {
    existing_ecr_registry = "123456789012.dkr.ecr.us-west-2.amazonaws.com/fortiaigate-lab"
    allowed_https_ip      = "203.0.113.10"
  }
  assert {
    condition     = length(aws_security_group.host.ingress) == 1 && one(aws_security_group.host.ingress).from_port == 443 && one(aws_security_group.host.ingress).to_port == 443 && one(aws_security_group.host.ingress).protocol == "tcp" && contains(one(aws_security_group.host.ingress).cidr_blocks, "203.0.113.10/32") && length(one(aws_security_group.host.ingress).cidr_blocks) == 1
    error_message = "Allow only TCP 443 from the supplied single IPv4 address."
  }
}

run "clear_https_access" {
  command = apply
  variables {
    existing_ecr_registry = "123456789012.dkr.ecr.us-west-2.amazonaws.com/fortiaigate-lab"
    allowed_https_ip      = ""
  }
  assert {
    condition     = length(aws_security_group.host.ingress) == 0
    error_message = "Clearing the IP must remove previously configured inbound access."
  }
}

run "reject_https_cidr" {
  command = plan
  variables {
    allowed_https_ip = "0.0.0.0/0"
  }
  expect_failures = [var.allowed_https_ip]
}

run "reject_invalid_https_ip" {
  command = plan
  variables {
    allowed_https_ip = "999.1.2.3"
  }
  expect_failures = [var.allowed_https_ip]
}

run "automatic_capacity_placement" {
  command = apply
  variables {
    availability_zone     = null
    existing_ecr_registry = "123456789012.dkr.ecr.us-west-2.amazonaws.com/fortiaigate-lab"
  }
  override_data {
    target = data.aws_instances.automatic["us-west-2b"]
    values = { ids = ["i-0123456789abcdef0"] }
  }
  assert {
    condition     = length(aws_instance.host) == 0 && length(aws_autoscaling_group.host) == 1 && length(aws_subnet.candidate) == 1 && aws_subnet.candidate["us-west-2b"].availability_zone == "us-west-2b"
    error_message = "An unset AZ must enable placement across all offered, available AZs."
  }
  assert {
    condition     = aws_autoscaling_group.host[0].min_size == 1 && aws_autoscaling_group.host[0].max_size == 1 && aws_autoscaling_group.host[0].desired_capacity == 1 && length(aws_autoscaling_group.host[0].vpc_zone_identifier) == 2
    error_message = "Automatic placement must request exactly one instance across both offered subnets."
  }
  assert {
    condition     = aws_autoscaling_group.host[0].availability_zone_distribution[0].capacity_distribution_strategy == "balanced-best-effort" && aws_autoscaling_group.host[0].ignore_failed_scaling_activities && aws_autoscaling_group.host[0].wait_for_capacity_timeout == "20m"
    error_message = "Capacity failures must allow retrying another AZ during the bounded Terraform wait."
  }
  assert {
    condition     = contains(aws_autoscaling_group.host[0].suspended_processes, "AZRebalance") && contains(aws_autoscaling_group.host[0].suspended_processes, "ReplaceUnhealthy")
    error_message = "Do not automatically rebalance or replace this stateful application host."
  }
  assert {
    condition     = aws_launch_template.host[0].instance_type == "g6e.2xlarge" && aws_launch_template.host[0].metadata_options[0].http_tokens == "required" && aws_launch_template.host[0].metadata_options[0].http_put_response_hop_limit == 1
    error_message = "The automatic host must retain the GPU type and IMDSv2 restrictions."
  }
  assert {
    condition     = one(aws_launch_template.host[0].block_device_mappings).device_name == "/dev/sda1" && one(aws_launch_template.host[0].block_device_mappings).ebs[0].encrypted && one(aws_launch_template.host[0].block_device_mappings).ebs[0].volume_size == 300
    error_message = "Use the AMI's root device with encrypted, correctly sized EBS storage."
  }
  assert {
    condition     = strcontains(base64decode(aws_launch_template.host[0].user_data), "config['data-root'] = '/var/lib/docker'") && one(aws_launch_template.host[0].network_interfaces).associate_public_ip_address
    error_message = "Automatic placement must preserve persistent Docker storage and outbound internet access."
  }
  assert {
    condition     = output.instance_id == "i-0123456789abcdef0" && output.availability_zone == "us-west-2b" && strcontains(output.session_command, "i-0123456789abcdef0") && strcontains(output.webui_tunnel_command, "i-0123456789abcdef0")
    error_message = "Outputs must point to the launched instance and actual AZ, not the first candidate AZ."
  }
}

run "missing_automatic_instance" {
  command = apply
  variables {
    availability_zone     = null
    existing_ecr_registry = "123456789012.dkr.ecr.us-west-2.amazonaws.com/fortiaigate-lab"
  }
  assert {
    condition     = output.instance_id == null && output.availability_zone == null && output.session_command == null && output.webui_tunnel_command == null
    error_message = "An empty group must produce no connection outputs rather than failing or retaining a deleted instance ID."
  }
  assert {
    condition     = length(aws_autoscaling_group.host) == 1 && aws_autoscaling_group.host[0].desired_capacity == 1
    error_message = "A missing instance must not remove the group or change its desired capacity."
  }
}

run "reject_region_without_offered_az" {
  command = plan
  variables {
    availability_zone = null
  }
  override_data {
    target = data.aws_ec2_instance_type_offerings.gpu
    values = { locations = [] }
  }
  expect_failures = [aws_subnet.lab]
}

# Plan the upload path without executing its local Docker/AWS provisioner.
run "create_and_upload_images" {
  command = plan
  assert {
    condition     = length(aws_ecr_repository.component) == 10 && alltrue([for repo in aws_ecr_repository.component : repo.image_tag_mutability == "IMMUTABLE"])
    error_message = "All ten component repositories must preserve published tags."
  }
  assert {
    condition     = length(terraform_data.publish_images) == 1 && terraform_data.publish_images[0].triggers_replace.build == "0055"
    error_message = "New registries must upload the selected release before launching the host."
  }
}

run "create_utility_bucket" {
  command = plan
  assert {
    condition     = length(aws_s3_bucket.utility) == 1 && length(aws_s3_bucket_policy.utility) == 1 && aws_s3_bucket_public_access_block.utility[0].block_public_policy && aws_s3_bucket_server_side_encryption_configuration.utility[0].rule != null
    error_message = "An empty bucket setting must create a private, encrypted bucket with a TLS policy."
  }
}

run "reuse_existing_utility_bucket" {
  command = apply
  variables {
    existing_ecr_registry = "123456789012.dkr.ecr.us-west-2.amazonaws.com/fortiaigate-lab"
    existing_s3_bucket    = "shared-deployment-artifacts"
  }
  assert {
    condition     = length(aws_s3_bucket.utility) == 0 && length(aws_s3_bucket_public_access_block.utility) == 0 && length(aws_s3_bucket_server_side_encryption_configuration.utility) == 0 && length(aws_s3_bucket_policy.utility) == 0
    error_message = "An existing bucket must not be created or have its settings or policy managed."
  }
  assert {
    condition     = aws_s3_object.utility.bucket == "shared-deployment-artifacts" && strcontains(aws_instance.host[0].user_data, "s3://shared-deployment-artifacts/${aws_s3_object.utility.key}")
    error_message = "The archive upload and bootstrap download must use the existing bucket."
  }
  assert {
    condition     = startswith(aws_s3_object.utility.key, "fortiaigate/${aws_iam_role.host.name}/cli/")
    error_message = "Deployments sharing a bucket must use separate utility objects."
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.artifacts.policy).Statement[2].Resource == aws_s3_object.utility.arn && jsondecode(aws_iam_role_policy.artifacts.policy).Statement[2].Action == ["s3:GetObject"]
    error_message = "The instance must have read access to only the uploaded utility object."
  }
}

run "reject_bucket_uri" {
  command = plan
  variables {
    existing_s3_bucket = "s3://shared-deployment-artifacts/path"
  }
  expect_failures = [var.existing_s3_bucket]
}

run "reuse_existing_registry" {
  command = apply
  variables {
    existing_ecr_registry = "987654321098.dkr.ecr.us-east-1.amazonaws.com/shared/fortiaigate"
    image_archive_dir     = "/does/not/exist"
  }
  assert {
    condition     = length(aws_ecr_repository.component) == 0 && length(terraform_data.publish_images) == 0
    error_message = "Existing registries must skip repository creation and all local image uploads."
  }
  assert {
    condition     = output.registry_path == "987654321098.dkr.ecr.us-east-1.amazonaws.com/shared/fortiaigate" && output.repository_urls["api"] == "987654321098.dkr.ecr.us-east-1.amazonaws.com/shared/fortiaigate/api"
    error_message = "Outputs must use the supplied registry and nested repository prefix."
  }
  assert {
    condition     = length(jsondecode(aws_iam_role_policy.artifacts.policy).Statement[1].Resource) == 10 && contains(jsondecode(aws_iam_role_policy.artifacts.policy).Statement[1].Resource, "arn:aws:ecr:us-east-1:987654321098:repository/shared/fortiaigate/api")
    error_message = "Pull permissions must target existing repositories in the correct account and region."
  }
  assert {
    condition     = strcontains(aws_instance.host[0].user_data, "export ECR_REGION='us-east-1'") && strcontains(aws_instance.host[0].user_data, "export ECR_REGISTRY_PATH='987654321098.dkr.ecr.us-east-1.amazonaws.com/shared/fortiaigate'")
    error_message = "The host must log into the supplied ECR registry in its own region."
  }
}

run "reuse_registry_without_prefix" {
  command = plan
  variables {
    existing_ecr_registry = "987654321098.dkr.ecr.us-west-2.amazonaws.com"
  }
  assert {
    condition     = contains(local.repository_arns, "arn:aws:ecr:us-west-2:987654321098:repository/api")
    error_message = "Registries without a prefix must use component repositories at the root."
  }
}

run "reject_invalid_registry" {
  command = plan
  variables {
    existing_ecr_registry = "https://example.com/fortiaigate"
  }
  expect_failures = [var.existing_ecr_registry]
}

run "reject_unavailable_az" {
  command = plan
  variables {
    availability_zone = "us-west-2c"
  }
  expect_failures = [aws_subnet.lab]
}

run "reject_undersized_gpu_host" {
  command = plan
  variables {
    instance_type = "g6e.xlarge"
  }
  expect_failures = [var.instance_type]
}
