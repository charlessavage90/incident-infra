variable "posture" {
  type        = string
  description = <<-EOT
    active  - appliance running, interface endpoints created
    dormant - appliance stopped, interface endpoints destroyed, data untouched

    Dormancy is a state toggle, never a destroy. The EBS data volume, S3, VPC,
    DNS, and DynamoDB are owned by the platform layer and are not affected.
  EOT
  default     = "dormant"

  validation {
    condition     = contains(["active", "dormant"], var.posture)
    error_message = "posture must be \"active\" or \"dormant\"."
  }
}

variable "instance_type" {
  type        = string
  description = <<-EOT
    Appliance size. Because the instance is stopped between incidents and the data
    lives on a separate volume owned by the platform layer, this is a per-incident
    dial rather than a commitment:

      r6i.large    2 vCPU / 16 GiB  - 1-3 responders, modest timelines (default)
      r6i.xlarge   4 vCPU / 32 GiB  - 3-6 responders, sustained ingest
      r6i.2xlarge  8 vCPU / 64 GiB  - large case, multi-TB timelines

    At the default OpenSearch receives 8 GiB of heap. Two vCPU is thin for bulk
    indexing; resizing for a large case is the release valve.
  EOT
  default     = "r6i.large"
}

variable "root_volume_gb" {
  type        = number
  description = "Root volume size. Holds the OS and container images only; data lives on the platform volume."
  default     = 50
}

variable "responders" {
  type        = list(string)
  description = <<-EOT
    Timesketch usernames to provision. Named accounts, never shared: Timesketch
    attributes every comment, tag, star, and saved search to a user, and a shared
    login destroys that attribution (spec 3.4).
  EOT
  default     = []
}

# --- Consumed from the platform layer ---

variable "name_prefix" {
  type        = string
  description = "Prefix from the platform layer."
}

variable "vpc_id" {
  type        = string
  description = "IR VPC ID."
}

variable "vpc_cidr" {
  type        = string
  description = "IR VPC CIDR, for the endpoint security group."
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnets. The appliance launches in the first."
}

variable "data_volume_id" {
  type        = string
  description = "Persistent data volume, owned by the platform layer."
}

variable "data_volume_availability_zone" {
  type        = string
  description = "The appliance must launch here; EBS attaches only within one AZ."
}

variable "kms_key_arn" {
  type        = string
  description = "Platform CMK."
}

variable "appliance_instance_profile_name" {
  type        = string
  description = "Instance profile granting SSM, ECR pull, and secret read."
}

variable "appliance_security_group_id" {
  type        = string
  description = "Appliance security group, the org-connector attachment surface."
}

variable "private_zone_id" {
  type        = string
  description = "Private hosted zone ID."
}

variable "private_zone_name" {
  type        = string
  description = "Private hosted zone name."
}

variable "image_digest_parameter_prefix" {
  type        = string
  description = "SSM path holding repo@digest references, published by the images module."
}

variable "tags" {
  type        = map(string)
  description = "Additional tags applied to every resource."
  default     = {}
}
