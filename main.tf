data "aws_partition" "current" {}

data "aws_ssm_parameter" "dlami" {
  count = var.ami_id == null ? 1 : 0
  name  = "/aws/service/deeplearning/ami/x86_64/base-oss-nvidia-driver-gpu-ubuntu-22.04/latest/ami-id"
}

data "aws_ec2_instance_type_offerings" "gpu" {
  location_type = "availability-zone"
  filter {
    name   = "instance-type"
    values = [var.instance_type]
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  automatic_placement = var.availability_zone == null
  ami_id              = var.ami_id != null ? var.ami_id : nonsensitive(data.aws_ssm_parameter.dlami[0].value)
  gpu_azs = sort(tolist(setintersection(
    toset(data.aws_ec2_instance_type_offerings.gpu.locations),
    toset(data.aws_availability_zones.available.names)
  )))
  availability_zone = var.availability_zone != null ? var.availability_zone : try(local.gpu_azs[0], "")
  components = toset([
    "api", "webui", "llm-gateway", "logd", "license_manager",
    "guardrail", "guardrail-scanner", "custom-triton", "faig-models", "vllm-server"
  ])
  use_existing_ecr = var.existing_ecr_registry != ""
  registry_path    = local.use_existing_ecr ? trimsuffix(var.existing_ecr_registry, "/") : trimsuffix(aws_ecr_repository.component["api"].repository_url, "/api")
  registry         = split("/", local.registry_path)[0]
  ecr_region       = split(".", local.registry)[3]
  ecr_account      = split(".", local.registry)[0]
  ecr_prefix       = join("/", slice(split("/", local.registry_path), 1, length(split("/", local.registry_path))))
  repository_urls  = { for component in local.components : component => "${local.registry_path}/${component}" }
  repository_arns = local.use_existing_ecr ? [
    for component in local.components : "arn:${data.aws_partition.current.partition}:ecr:${local.ecr_region}:${local.ecr_account}:repository/${local.ecr_prefix == "" ? "" : "${local.ecr_prefix}/"}${component}"
  ] : [for repo in aws_ecr_repository.component : repo.arn]
  use_existing_s3 = var.existing_s3_bucket != ""
  utility_bucket  = local.use_existing_s3 ? var.existing_s3_bucket : aws_s3_bucket.utility[0].id
  bootstrap = templatefile("${path.module}/templates/bootstrap.sh.tftpl", {
    region         = var.aws_region
    utility_uri    = "s3://${local.utility_bucket}/${aws_s3_object.utility.key}"
    utility_sha256 = filesha256(var.utility_archive)
    registry       = local.registry
    registry_path  = local.registry_path
    ecr_region     = local.ecr_region
    image_version  = var.fortiaigate_version
    image_build    = var.fortiaigate_build
  })
  automatic_hosts = flatten([
    for az, instances in data.aws_instances.automatic : [
      for id in sort(instances.ids) : { id = id, az = az }
    ]
  ])
  host_id = local.automatic_placement ? try(local.automatic_hosts[0].id, null) : aws_instance.host[0].id
  host_az = local.automatic_placement ? try(local.automatic_hosts[0].az, null) : aws_instance.host[0].availability_zone
}

resource "aws_vpc" "lab" {
  cidr_block           = "10.42.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = var.name }
}

resource "aws_internet_gateway" "lab" {
  vpc_id = aws_vpc.lab.id
}

resource "aws_subnet" "lab" {
  vpc_id            = aws_vpc.lab.id
  cidr_block        = "10.42.1.0/24"
  availability_zone = local.availability_zone
  tags              = { Name = "${var.name}-public" }
  lifecycle {
    precondition {
      condition     = contains(local.gpu_azs, local.availability_zone)
      error_message = "No usable AZ offers this instance type. Choose another region or an AZ offering the selected type."
    }
  }
}

resource "aws_route_table" "lab" {
  vpc_id = aws_vpc.lab.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lab.id
  }
}

resource "aws_route_table_association" "lab" {
  subnet_id      = aws_subnet.lab.id
  route_table_id = aws_route_table.lab.id
}

# Keep the original primary subnet, adding one per other offered AZ in automatic mode.
resource "aws_subnet" "candidate" {
  for_each = local.automatic_placement ? toset([
    for az in local.gpu_azs : az if az != local.availability_zone
  ]) : toset([])
  vpc_id            = aws_vpc.lab.id
  cidr_block        = cidrsubnet(aws_vpc.lab.cidr_block, 8, index(local.gpu_azs, each.key) + 2)
  availability_zone = each.key
  tags              = { Name = "${var.name}-${each.key}-public" }
}

resource "aws_route_table_association" "candidate" {
  for_each       = aws_subnet.candidate
  subnet_id      = each.value.id
  route_table_id = aws_route_table.lab.id
}

resource "aws_security_group" "host" {
  name_prefix = "${var.name}-"
  description = "No inbound access; use SSM shell and port forwarding."
  vpc_id      = aws_vpc.lab.id
  # Explicit [] also removes the managed rule when allowed_https_ip is cleared.
  ingress = var.allowed_https_ip == "" ? [] : [{
    description      = "HTTPS from operator IP"
    from_port        = 443
    to_port          = 443
    protocol         = "tcp"
    cidr_blocks      = ["${var.allowed_https_ip}/32"]
    ipv6_cidr_blocks = []
    prefix_list_ids  = []
    security_groups  = []
    self             = false
  }]
  # Outbound internet is needed for SSM, ECR/S3, packages, Docker Hub and FortiCare.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_ecr_repository" "component" {
  for_each             = local.use_existing_ecr ? toset([]) : local.components
  name                 = "${var.name}/${each.key}"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = var.force_destroy_artifacts
  image_scanning_configuration {
    scan_on_push = true
  }
  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "terraform_data" "publish_images" {
  count = local.use_existing_ecr ? 0 : 1
  triggers_replace = {
    registry_path = local.registry_path
    archive_dir   = abspath(pathexpand(var.image_archive_dir))
    version       = var.fortiaigate_version
    build         = var.fortiaigate_build
    script_hash   = filesha256("${path.module}/scripts/publish-images.sh")
  }
  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = "bash \"$PUBLISH_SCRIPT\" \"$REGISTRY_PATH\" \"$IMAGE_VERSION\" \"$IMAGE_BUILD\" \"$ARCHIVE_DIR\""
    environment = {
      PUBLISH_SCRIPT     = abspath("${path.module}/scripts/publish-images.sh")
      AWS_DEFAULT_REGION = var.aws_region
      REGISTRY_PATH      = local.registry_path
      IMAGE_VERSION      = var.fortiaigate_version
      IMAGE_BUILD        = var.fortiaigate_build
      ARCHIVE_DIR        = abspath(pathexpand(var.image_archive_dir))
    }
  }
  depends_on = [aws_ecr_repository.component]
}

resource "aws_s3_bucket" "utility" {
  count         = local.use_existing_s3 ? 0 : 1
  bucket_prefix = "${var.name}-utility-"
  force_destroy = var.force_destroy_artifacts
}

resource "aws_s3_bucket_public_access_block" "utility" {
  count                   = local.use_existing_s3 ? 0 : 1
  bucket                  = aws_s3_bucket.utility[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "utility" {
  count  = local.use_existing_s3 ? 0 : 1
  bucket = aws_s3_bucket.utility[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_policy" "utility" {
  count  = local.use_existing_s3 ? 0 : 1
  bucket = aws_s3_bucket.utility[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Deny", Principal = "*", Action = "s3:*"
      Resource  = [aws_s3_bucket.utility[0].arn, "${aws_s3_bucket.utility[0].arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

resource "aws_s3_object" "utility" {
  bucket = local.utility_bucket
  # Separate deployments sharing a bucket must not own/delete the same object.
  key         = "fortiaigate/${aws_iam_role.host.name}/cli/${filesha256(var.utility_archive)}.tar.gz"
  source      = var.utility_archive
  source_hash = filesha256(var.utility_archive)
  depends_on  = [aws_s3_bucket_server_side_encryption_configuration.utility, aws_s3_bucket_public_access_block.utility]
}

resource "aws_iam_role" "host" {
  name_prefix = "${var.name}-"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.host.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "artifacts" {
  role = aws_iam_role.host.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["ecr:GetAuthorizationToken"], Resource = "*" },
      {
        Effect   = "Allow"
        Action   = ["ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage"]
        Resource = local.repository_arns
      },
      { Effect = "Allow", Action = ["s3:GetObject"], Resource = aws_s3_object.utility.arn }
    ]
  })
}

resource "aws_iam_instance_profile" "host" {
  name_prefix = "${var.name}-"
  role        = aws_iam_role.host.name
}

resource "aws_instance" "host" {
  count                       = local.automatic_placement ? 0 : 1
  ami                         = local.ami_id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.lab.id
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.host.id]
  iam_instance_profile        = aws_iam_instance_profile.host.name
  user_data_replace_on_change = true
  user_data                   = local.bootstrap
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }
  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size
    encrypted             = true
    delete_on_termination = true
  }
  tags = { Name = var.name }
  depends_on = [
    aws_route_table_association.lab,
    aws_iam_role_policy_attachment.ssm,
    aws_iam_role_policy.artifacts,
    terraform_data.publish_images
  ]
}
