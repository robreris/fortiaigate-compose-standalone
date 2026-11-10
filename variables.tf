variable "aws_region" {
  description = "Region offering the selected GPU instance type with sufficient On-Demand G/VT vCPU quota."
  type        = string
  default     = "us-west-2"
}

variable "name" {
  description = "Short lowercase name used for resources and the ECR repository prefix."
  type        = string
  default     = "fortiaigate-lab"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,29}$", var.name))
    error_message = "Use 3–30 lowercase letters, digits, or hyphens, starting with a letter."
  }
}

variable "availability_zone" {
  description = "Pin one AZ, or leave null to let a one-instance Auto Scaling group retry across offered AZs in aws_region."
  type        = string
  default     = null
}

variable "allowed_https_ip" {
  description = "Optional public IPv4 address allowed inbound HTTPS on port 443. Supply only the IP; /32 is added automatically. Empty disables inbound access."
  type        = string
  default     = ""
  nullable    = false
  validation {
    condition     = var.allowed_https_ip == "" || can(cidrnetmask("${var.allowed_https_ip}/32"))
    error_message = "Use a single IPv4 address such as 203.0.113.10, without /32, or leave empty."
  }
}

variable "instance_type" {
  description = "Single-GPU instance type. G6e defaults meet the 8 vCPU / 64 GiB guidance; g5.2xlarge is allowed for smaller lab trials with 32 GiB host RAM."
  type        = string
  default     = "g6e.2xlarge"
  validation {
    condition     = contains(["g5.2xlarge", "g6e.2xlarge", "g6e.4xlarge", "g6e.8xlarge", "g6e.16xlarge"], var.instance_type)
    error_message = "Select g5.2xlarge for a smaller lab trial, or g6e.2xlarge, g6e.4xlarge, g6e.8xlarge, or g6e.16xlarge."
  }
}

variable "ami_id" {
  description = "Optional pinned AWS Deep Learning Base OSS NVIDIA Ubuntu 22.04 x86_64 AMI ID. Null resolves the current public SSM parameter."
  type        = string
  default     = null
}

variable "root_volume_size" {
  description = "Encrypted persistent gp3 root disk in GiB, including OS, Docker images/volumes, models, and backups."
  type        = number
  default     = 300
  validation {
    condition     = var.root_volume_size >= 200 && floor(var.root_volume_size) == var.root_volume_size
    error_message = "Use an integer of at least 200 GiB to leave room for the DLAMI and application images."
  }
}

variable "utility_archive" {
  description = "Path to the original Fortinet CLI archive, relative to this Terraform directory or absolute."
  type        = string
  default     = "FAIG_deploy-docker-compose-cli-V8.0.2-build0055-FORTINET.tar.gz"
}

variable "existing_s3_bucket" {
  description = "Existing S3 bucket name for uploading the utility archive. Empty creates a private bucket. Existing bucket settings are not managed."
  type        = string
  default     = ""
  nullable    = false
  validation {
    condition = var.existing_s3_bucket == "" || (
      length(var.existing_s3_bucket) >= 3 && length(var.existing_s3_bucket) <= 63 &&
      can(regex("^[a-z0-9][a-z0-9.-]*[a-z0-9]$", var.existing_s3_bucket))
    )
    error_message = "Use an S3 bucket name (3–63 lowercase letters, digits, dots, or hyphens), without s3:// or a path, or leave empty."
  }
}

variable "force_destroy_artifacts" {
  description = "Allow terraform destroy to delete nonempty ECR repositories and the utility S3 bucket. Opt in only for disposable labs."
  type        = bool
  default     = false
}

variable "existing_ecr_registry" {
  description = "Existing private ECR registry/path containing all ten images. Empty creates repositories and uploads local archives. No https:// or component name."
  type        = string
  default     = ""
  nullable    = false
  validation {
    condition     = var.existing_ecr_registry == "" || can(regex("^[0-9]{12}\\.dkr\\.ecr\\.[a-z0-9-]+\\.amazonaws\\.com(\\.cn)?(/[a-z0-9][a-z0-9/_-]*)?$", var.existing_ecr_registry))
    error_message = "Use an ECR address such as 123456789012.dkr.ecr.us-west-2.amazonaws.com/fortiaigate, or leave empty."
  }
}

variable "image_archive_dir" {
  description = "Local folder containing the ten Fortinet component archives; used only when existing_ecr_registry is empty."
  type        = string
  default     = "./images"
}

variable "fortiaigate_version" {
  description = "Application image release version."
  type        = string
  default     = "8.0.2"
  validation {
    condition     = can(regex("^[0-9]+(\\.[0-9]+)+$", var.fortiaigate_version))
    error_message = "Use a numeric release such as 8.0.2."
  }
}

variable "fortiaigate_build" {
  description = "Application image build; preserve leading zeros from the archive filenames."
  type        = string
  default     = "0055"
  validation {
    condition     = can(regex("^[0-9]+$", var.fortiaigate_build))
    error_message = "Use a numeric build string such as 0055."
  }
}
