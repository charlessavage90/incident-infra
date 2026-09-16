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

# --- Phase 3: the ingest pipeline ---

variable "evidence_bucket" {
  type        = string
  description = "Evidence bucket name, from the platform layer."
}

variable "evidence_bucket_arn" {
  type        = string
  description = "Evidence bucket ARN, from the platform layer."
}

variable "plaso_bucket" {
  type        = string
  description = "Destination bucket for .plaso files, from the platform layer."
}

variable "plaso_bucket_arn" {
  type        = string
  description = "Plaso bucket ARN, from the platform layer."
}

variable "artifacts_table" {
  type        = string
  description = "Artifact manifest table name, from the platform layer."
}

variable "artifacts_table_arn" {
  type        = string
  description = "Artifact manifest table ARN, from the platform layer."
}

# Instance families carrying NVMe instance storage.
#
# This is amendment A9's argument made concrete: plaso is disk-bound and D8
# targets 100 GB to 1 TB per incident, so scratch is local NVMe rather than a
# network volume attached per task. An instance type without instance storage
# still works -- templates/scratch.sh.tftpl falls back to the root volume -- but
# slowly, and the fallback is a safety net, not a plan.
variable "worker_instance_types" {
  type        = list(string)
  description = "Batch compute environment instance types. Must carry NVMe instance storage."
  default     = ["i4i.2xlarge", "c6id.4xlarge"]
}

# Sized to consume a whole instance, which is how Batch on EC2 approximates the
# per-task isolation Fargate gives structurally. A fleet processing live malware
# should not co-schedule two cases on one kernel.
variable "worker_job_vcpus" {
  type        = number
  description = "vCPUs per job. Set to a whole instance's count to keep one job per host."
  default     = 8
}

variable "worker_job_memory_mib" {
  type        = number
  description = "Memory per job, MiB. Leave headroom below the instance total for the ECS agent."
  default     = 58000
}

variable "worker_max_vcpus" {
  type        = number
  description = "Ceiling on the compute environment. Bounds spend during a large incident."
  default     = 64
}

variable "worker_root_volume_gb" {
  type        = number
  description = "Root volume for worker instances. Scratch is instance store; this is the OS and image layers only."
  default     = 100
}
