# Phase 1: Platform and Appliance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the permanent platform layer and a Timesketch appliance in AWS, reachable only over SSM, that survives a dormant→active cycle with its data intact.

**Architecture:** Three OpenTofu modules with independent state. `platform/` holds everything permanent — network, KMS, the EBS data volume, ECR, budget alarm. `images/` mirrors upstream container images into ECR by digest, outside the VPC. `analysis/` holds the toggleable appliance and its VPC endpoints, driven by a `posture` variable that stops the instance and destroys endpoints rather than destroying data.

**Tech Stack:** OpenTofu 1.12.6, AWS provider 6.64.0, Amazon Linux 2023, Docker Compose, Timesketch 20260630, OpenSearch 2.19.5, PostgreSQL 13.0-alpine, Redis 7.2.11-alpine, nginx 1.25.5-alpine-slim.

**Spec:** `docs/superpowers/specs/2026-09-14-ir-infrastructure-design.md`

## Global Constraints

Every task's requirements implicitly include this section.

- **IaC tool:** OpenTofu `1.12.6` (D16). CLI is `tofu`, never `terraform`.
- **AWS provider:** `hashicorp/aws` pinned to `6.64.0`. `.terraform.lock.hcl` is committed.
- **No internet gateway and no NAT gateway** in the IR VPC unless `enable_internet_egress = true` (spec §3.3).
- **No public ingress.** No public IPs, no internet-facing load balancers (D6).
- **All buckets, volumes, and named resources carry `var.name_prefix`** — bucket names are globally unique (spec §5.2.2).
- **Encryption at rest uses the platform CMK**, not AWS-managed keys.
- **Object Lock compliance mode is out of scope for Phase 1.** Evidence buckets arrive in Phase 2.
- **Container image versions are pinned to these exact values**, matching Timesketch's own `config.env`:
  - `TIMESKETCH_VERSION=20260630`
  - `OPENSEARCH_VERSION=2.19.5`
  - `POSTGRES_VERSION=13.0-alpine`
  - `REDIS_VERSION=7.2.11-alpine`
  - `NGINX_VERSION=1.25.5-alpine-slim`
- **Default instance type is `r6i.large`** (spec §3.4). Never hardcode a larger default.
- **Tests use `mock_provider`** so `tofu test` runs offline in CI with no AWS credentials and no cost.

---

## File Structure

| File | Responsibility |
|---|---|
| `.github/workflows/ci.yml` | fmt, validate, tflint, tofu test on every push |
| `.tflint.hcl` | Lint ruleset |
| `Makefile` | `make fmt`, `make test`, `make dormant`, `make active` |
| `modules/platform/versions.tf` | Provider and OpenTofu version pins |
| `modules/platform/variables.tf` | Platform inputs |
| `modules/platform/budget.tf` | AWS Budgets alarm — applied before anything costly |
| `modules/platform/kms.tf` | Customer-managed key + alias |
| `modules/platform/network.tf` | VPC, private subnets, route tables, S3 gateway endpoint, appliance SG |
| `modules/platform/dns.tf` | Route 53 private hosted zone |
| `modules/platform/storage.tf` | EBS data volume (the permanent-layer keystone) |
| `modules/platform/ecr.tf` | ECR repositories |
| `modules/platform/iam.tf` | Appliance instance role and profile |
| `modules/platform/outputs.tf` | Attachment surface consumed by `analysis/` and by org connectors |
| `modules/platform/tests/*.tftest.hcl` | Offline plan tests |
| `modules/images/codebuild.tf` | Mirror project, runs outside the VPC |
| `modules/images/buildspec.yml` | Pull upstream, push to ECR, publish digests to SSM |
| `modules/analysis/variables.tf` | Analysis inputs including `posture` |
| `modules/analysis/endpoints.tf` | VPC interface endpoints, posture-gated |
| `modules/analysis/appliance.tf` | EC2 instance, volume attachment, instance state |
| `modules/analysis/templates/cloud-init.sh.tftpl` | Host prep, volume mount, compose up |
| `modules/analysis/templates/docker-compose.yml.tftpl` | Timesketch stack, ECR image refs |
| `modules/analysis/templates/timesketch.conf.tftpl` | Application config |
| `modules/analysis/secrets.tf` | Generated secrets → Secrets Manager |
| `modules/analysis/users.tf` | Responder account provisioning via SSM document |
| `envs/example/` | Reference wiring of all three modules |

---

### Task 1: Toolchain, scaffolding, and CI

**Files:**
- Create: `Makefile`, `.tflint.hcl`, `.github/workflows/ci.yml`
- Create: `modules/platform/versions.tf`

**Interfaces:**
- Consumes: nothing
- Produces: `make fmt`, `make validate`, `make test` targets used by every later task

- [ ] **Step 1: Install OpenTofu**

```bash
winget install --id=OpenTofu.Tofu -e --version 1.12.6
```

Then open a new shell and verify:

```bash
tofu version
```

Expected: `OpenTofu v1.12.6`

- [ ] **Step 2: Write the version pin file**

Create `modules/platform/versions.tf`:

```hcl
terraform {
  required_version = "~> 1.12.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.64.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
```

- [ ] **Step 3: Write the lint config**

Create `.tflint.hcl`:

```hcl
plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.44.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}
```

- [ ] **Step 4: Write the Makefile**

Create `Makefile`:

```makefile
MODULES := modules/platform modules/images modules/analysis

.PHONY: fmt validate lint test check

fmt:
	tofu fmt -recursive

fmt-check:
	tofu fmt -recursive -check

validate:
	@for m in $(MODULES); do \
		echo "== $$m =="; \
		(cd $$m && tofu init -backend=false -input=false && tofu validate) || exit 1; \
	done

lint:
	tflint --recursive

test:
	@for m in $(MODULES); do \
		echo "== $$m =="; \
		(cd $$m && tofu test) || exit 1; \
	done

check: fmt-check validate lint test
```

- [ ] **Step 5: Write the CI workflow**

Create `.github/workflows/ci.yml`:

```yaml
name: ci

on:
  push:
    branches: ["**"]
  pull_request:

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: opentofu/setup-opentofu@v1
        with:
          tofu_version: 1.12.6

      - uses: terraform-linters/setup-tflint@v4
        with:
          tflint_version: v0.52.0

      - name: tofu fmt
        run: tofu fmt -recursive -check

      - name: tflint
        run: |
          tflint --init
          tflint --recursive

      - name: validate and test
        run: |
          for m in modules/platform modules/images modules/analysis; do
            echo "== $m =="
            (cd "$m" && tofu init -backend=false -input=false && tofu validate && tofu test)
          done
```

- [ ] **Step 6: Create placeholder module directories so CI does not fail on missing paths**

```bash
mkdir -p modules/images modules/analysis modules/platform/tests
cp modules/platform/versions.tf modules/images/versions.tf
cp modules/platform/versions.tf modules/analysis/versions.tf
```

- [ ] **Step 7: Verify locally**

Run: `make fmt-check validate`
Expected: PASS. `tofu test` with no test files reports no tests and exits 0.

- [ ] **Step 8: Commit**

```bash
git add Makefile .tflint.hcl .github/workflows/ci.yml modules/
git commit -m "build: add OpenTofu scaffolding, lint config, and CI"
```

---

### Task 2: Budget alarm and KMS key

The budget alarm ships first, deliberately. Spec §5.2.2: set it before the first apply, not after the first surprise.

**Files:**
- Create: `modules/platform/variables.tf`, `modules/platform/budget.tf`, `modules/platform/kms.tf`
- Test: `modules/platform/tests/foundations.tftest.hcl`

**Interfaces:**
- Consumes: nothing
- Produces: `aws_kms_key.main.arn` (used by Tasks 4, 8), `var.name_prefix`, `var.tags`, `local.common_tags`

- [ ] **Step 1: Write the failing test**

Create `modules/platform/tests/foundations.tftest.hcl`:

```hcl
mock_provider "aws" {}
mock_provider "random" {}

variables {
  name_prefix          = "ir-test"
  monthly_budget_usd   = 200
  budget_alert_emails  = ["responder@example.com"]
}

run "kms_key_rotates_annually" {
  command = plan

  assert {
    condition     = aws_kms_key.main.enable_key_rotation == true
    error_message = "Platform CMK must have automatic key rotation enabled."
  }
}

run "budget_alerts_before_overspend" {
  command = plan

  assert {
    condition     = aws_budgets_budget.monthly.limit_amount == "200"
    error_message = "Budget limit must come from var.monthly_budget_usd."
  }

  assert {
    condition     = length(aws_budgets_budget.monthly.notification) == 2
    error_message = "Budget must notify at both a forecast and an actual threshold."
  }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd modules/platform && tofu init -backend=false && tofu test`
Expected: FAIL — `Reference to undeclared resource "aws_kms_key" "main"`

- [ ] **Step 3: Write the variables**

Create `modules/platform/variables.tf`:

```hcl
variable "name_prefix" {
  type        = string
  description = "Prefix for all named resources. Bucket names are globally unique."

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$", var.name_prefix))
    error_message = "name_prefix must be lowercase alphanumeric with hyphens, 3-32 characters."
  }
}

variable "tags" {
  type        = map(string)
  description = "Additional tags applied to every resource."
  default     = {}
}

variable "monthly_budget_usd" {
  type        = number
  description = "Monthly spend threshold for the IR environment."
  default     = 200
}

variable "budget_alert_emails" {
  type        = list(string)
  description = "Addresses notified when the budget threshold is approached or breached."

  validation {
    condition     = length(var.budget_alert_emails) > 0
    error_message = "At least one budget alert address is required. Idle cost is the failure mode this guards."
  }
}
```

- [ ] **Step 4: Write the budget**

Create `modules/platform/budget.tf`:

```hcl
locals {
  common_tags = merge(var.tags, {
    ManagedBy = "opentofu"
    Component = "ir-platform"
  })
}

resource "aws_budgets_budget" "monthly" {
  name         = "${var.name_prefix}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Forecast alert fires early enough to act; actual alert is the backstop.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = var.budget_alert_emails
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = var.budget_alert_emails
  }
}
```

- [ ] **Step 5: Write the KMS key**

Create `modules/platform/kms.tf`:

```hcl
resource "aws_kms_key" "main" {
  description             = "${var.name_prefix} IR platform key"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  tags                    = local.common_tags
}

resource "aws_kms_alias" "main" {
  name          = "alias/${var.name_prefix}"
  target_key_id = aws_kms_key.main.key_id
}
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `cd modules/platform && tofu test`
Expected: PASS — 2 passed, 0 failed.

- [ ] **Step 7: Commit**

```bash
git add modules/platform/
git commit -m "feat(platform): add budget alarm and customer-managed KMS key"
```

---

### Task 3: Network

**Files:**
- Create: `modules/platform/network.tf`
- Modify: `modules/platform/variables.tf` (append)
- Test: `modules/platform/tests/network.tftest.hcl`

**Interfaces:**
- Consumes: `local.common_tags` (Task 2)
- Produces: `aws_vpc.main.id`, `aws_subnet.private[*].id`, `aws_security_group.appliance.id`, `aws_route_table.private.id`

- [ ] **Step 1: Write the failing test**

Create `modules/platform/tests/network.tftest.hcl`:

```hcl
mock_provider "aws" {}
mock_provider "random" {}

variables {
  name_prefix         = "ir-test"
  budget_alert_emails = ["responder@example.com"]
  vpc_cidr            = "10.90.0.0/16"
}

run "no_internet_gateway_by_default" {
  command = plan

  assert {
    condition     = length(aws_internet_gateway.main) == 0
    error_message = "The IR VPC must have no internet gateway unless enable_internet_egress is true."
  }

  assert {
    condition     = length(aws_nat_gateway.main) == 0
    error_message = "The IR VPC must have no NAT gateway unless enable_internet_egress is true."
  }
}

run "two_private_subnets_across_azs" {
  command = plan

  assert {
    condition     = length(aws_subnet.private) == 2
    error_message = "Two private subnets are required across two availability zones."
  }
}

run "appliance_security_group_denies_ingress_by_default" {
  command = plan

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.appliance_https) == 0
    error_message = "With no allowed_ingress_* inputs, the appliance SG must have zero ingress rules."
  }
}

run "s3_gateway_endpoint_exists" {
  command = plan

  assert {
    condition     = aws_vpc_endpoint.s3.vpc_endpoint_type == "Gateway"
    error_message = "S3 must use a gateway endpoint. ECR image layers are fetched from S3."
  }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd modules/platform && tofu test`
Expected: FAIL — `Reference to undeclared resource "aws_internet_gateway" "main"`

- [ ] **Step 3: Append the network variables**

Append to `modules/platform/variables.tf`:

```hcl
variable "vpc_cidr" {
  type        = string
  description = "CIDR for the IR VPC."
  default     = "10.90.0.0/16"
}

variable "enable_internet_egress" {
  type        = bool
  description = <<-EOT
    Adds an internet gateway and NAT gateway. Required only when an org-managed connector
    (for example a ZPA App Connector) must dial outbound to a vendor cloud. Default is no
    egress: this environment handles live malware.
  EOT
  default     = false
}

variable "allowed_ingress_cidrs" {
  type        = list(string)
  description = "CIDRs permitted to reach the appliance on 443. For org-managed connectivity."
  default     = []
}

variable "allowed_ingress_security_group_ids" {
  type        = list(string)
  description = "Security groups permitted to reach the appliance on 443."
  default     = []
}
```

- [ ] **Step 4: Write the network**

Create `modules/platform/network.tf`:

```hcl
data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-vpc" })
}

resource "aws_subnet" "private" {
  count = 2

  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  # No public IPs. Ever. (D6)
  map_public_ip_on_launch = false

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-private-${count.index}" })
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags   = merge(local.common_tags, { Name = "${var.name_prefix}-private" })
}

resource "aws_route_table_association" "private" {
  count = 2

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# --- Optional egress, off by default (spec 3.3) ---

resource "aws_internet_gateway" "main" {
  count = var.enable_internet_egress ? 1 : 0

  vpc_id = aws_vpc.main.id
  tags   = merge(local.common_tags, { Name = "${var.name_prefix}-igw" })
}

resource "aws_subnet" "public" {
  count = var.enable_internet_egress ? 1 : 0

  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 100)
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-public" })
}

resource "aws_eip" "nat" {
  count  = var.enable_internet_egress ? 1 : 0
  domain = "vpc"
  tags   = merge(local.common_tags, { Name = "${var.name_prefix}-nat" })
}

resource "aws_nat_gateway" "main" {
  count = var.enable_internet_egress ? 1 : 0

  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id

  depends_on = [aws_internet_gateway.main]
  tags       = merge(local.common_tags, { Name = "${var.name_prefix}-nat" })
}

resource "aws_route" "private_egress" {
  count = var.enable_internet_egress ? 1 : 0

  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main[0].id
}

# --- S3 gateway endpoint: free, and required for ECR image layer pulls ---

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-s3" })
}

data "aws_region" "current" {}

# --- Appliance security group: the attachment surface (spec 3.3) ---

resource "aws_security_group" "appliance" {
  name        = "${var.name_prefix}-appliance"
  description = "Timesketch appliance. Ingress only from org-managed connectors."
  vpc_id      = aws_vpc.main.id

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-appliance" })
}

resource "aws_vpc_security_group_ingress_rule" "appliance_https" {
  count = length(var.allowed_ingress_cidrs)

  security_group_id = aws_security_group.appliance.id
  cidr_ipv4         = var.allowed_ingress_cidrs[count.index]
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "Org-managed connector"
}

resource "aws_vpc_security_group_ingress_rule" "appliance_https_sg" {
  count = length(var.allowed_ingress_security_group_ids)

  security_group_id            = aws_security_group.appliance.id
  referenced_security_group_id = var.allowed_ingress_security_group_ids[count.index]
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  description                  = "Org-managed connector security group"
}

# Egress to VPC endpoints and, when enabled, the internet.
resource "aws_vpc_security_group_egress_rule" "appliance_all" {
  security_group_id = aws_security_group.appliance.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Outbound to VPC endpoints; no internet route exists by default"
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd modules/platform && tofu test`
Expected: PASS — 6 passed, 0 failed.

- [ ] **Step 6: Commit**

```bash
git add modules/platform/
git commit -m "feat(platform): add VPC with no default egress and connector attachment surface"
```

---

### Task 4: EBS data volume, private DNS, and ECR

The data volume is the keystone of spec §3.1 — it lives in the permanent layer so `tofu destroy` on `analysis/` loses nothing.

**Files:**
- Create: `modules/platform/storage.tf`, `modules/platform/dns.tf`, `modules/platform/ecr.tf`
- Modify: `modules/platform/variables.tf` (append)
- Test: `modules/platform/tests/storage.tftest.hcl`

**Interfaces:**
- Consumes: `aws_kms_key.main.arn` (Task 2), `aws_vpc.main.id` (Task 3)
- Produces: `aws_ebs_volume.data.id`, `aws_route53_zone.private.zone_id`, `aws_ecr_repository.mirror[*].repository_url`

- [ ] **Step 1: Write the failing test**

Create `modules/platform/tests/storage.tftest.hcl`:

```hcl
mock_provider "aws" {}
mock_provider "random" {}

variables {
  name_prefix         = "ir-test"
  budget_alert_emails = ["responder@example.com"]
  data_volume_gb      = 500
}

run "data_volume_is_encrypted_with_platform_key" {
  command = plan

  assert {
    condition     = aws_ebs_volume.data.encrypted == true
    error_message = "The data volume holds evidence-derived indices and must be encrypted."
  }

  assert {
    condition     = aws_ebs_volume.data.size == 500
    error_message = "Data volume size must come from var.data_volume_gb."
  }

  assert {
    condition     = aws_ebs_volume.data.type == "gp3"
    error_message = "Data volume must be gp3."
  }
}

run "data_volume_survives_destroy" {
  command = plan

  assert {
    condition     = aws_ebs_volume.data.lifecycle[0].prevent_destroy == true
    error_message = "The data volume must be protected from accidental destruction (spec 3.1)."
  }
}

run "ecr_repositories_scan_on_push" {
  command = plan

  assert {
    condition = alltrue([
      for r in aws_ecr_repository.mirror : r.image_scanning_configuration[0].scan_on_push
    ])
    error_message = "Mirrored images must be scanned on push."
  }

  assert {
    condition     = length(aws_ecr_repository.mirror) == 5
    error_message = "Five images are mirrored: timesketch, opensearch, postgres, redis, nginx."
  }
}
```

Note on the `prevent_destroy` assertion: OpenTofu does not expose `lifecycle` as a readable attribute. Replace that `run` block with the version in Step 5 after reading the note there.

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd modules/platform && tofu test`
Expected: FAIL — `Reference to undeclared resource "aws_ebs_volume" "data"`

- [ ] **Step 3: Append the variables**

Append to `modules/platform/variables.tf`:

```hcl
variable "data_volume_gb" {
  type        = number
  description = "Size of the persistent OpenSearch and PostgreSQL data volume."
  default     = 500
}

variable "private_zone_name" {
  type        = string
  description = "Private hosted zone name. Connector app segments reference names, not IPs."
  default     = "ir.internal"
}
```

- [ ] **Step 4: Write the storage**

Create `modules/platform/storage.tf`:

```hcl
# The keystone of spec 3.1. This volume lives in the permanent layer so that
# `tofu destroy` against modules/analysis loses no warm data.
resource "aws_ebs_volume" "data" {
  availability_zone = aws_subnet.private[0].availability_zone
  size              = var.data_volume_gb
  type              = "gp3"
  encrypted         = true
  kms_key_id        = aws_kms_key.main.arn

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-data"
    Role = "opensearch-and-postgres"
  })

  lifecycle {
    prevent_destroy = true
  }
}
```

- [ ] **Step 5: Correct the lifecycle assertion**

`lifecycle` is a meta-argument and is not readable in an assertion. Replace the
`data_volume_survives_destroy` run block in `tests/storage.tftest.hcl` with an assertion on the
property that actually matters — that the volume is pinned to the same AZ as the subnet the
appliance will launch in, since a cross-AZ volume cannot attach:

```hcl
run "data_volume_is_in_the_appliance_availability_zone" {
  command = plan

  assert {
    condition     = aws_ebs_volume.data.availability_zone == aws_subnet.private[0].availability_zone
    error_message = "EBS volumes attach only within one AZ. The data volume must match subnet 0."
  }
}
```

- [ ] **Step 6: Write the DNS**

Create `modules/platform/dns.tf`:

```hcl
# A stable name matters because connector application segments should reference
# a name that survives instance replacement, not an IP that does not (spec 3.3).
resource "aws_route53_zone" "private" {
  name = var.private_zone_name

  vpc {
    vpc_id = aws_vpc.main.id
  }

  tags = local.common_tags
}
```

- [ ] **Step 7: Write the ECR repositories**

Create `modules/platform/ecr.tf`:

```hcl
locals {
  mirrored_images = toset(["timesketch", "opensearch", "postgres", "redis", "nginx"])
}

resource "aws_ecr_repository" "mirror" {
  for_each = local.mirrored_images

  name                 = "${var.name_prefix}/${each.key}"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.main.arn
  }

  tags = local.common_tags
}

# Keep the mirror small: expire untagged layers left behind by re-pushes.
resource "aws_ecr_lifecycle_policy" "mirror" {
  for_each = aws_ecr_repository.mirror

  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire untagged images after 14 days"
      selection = {
        tagStatus   = "untagged"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = 14
      }
      action = { type = "expire" }
    }]
  })
}
```

- [ ] **Step 8: Run the test to verify it passes**

Run: `cd modules/platform && tofu test`
Expected: PASS — all run blocks pass.

- [ ] **Step 9: Commit**

```bash
git add modules/platform/
git commit -m "feat(platform): add persistent data volume, private DNS zone, and ECR mirror repos"
```

---

### Task 5: Instance IAM role and platform outputs

**Files:**
- Create: `modules/platform/iam.tf`, `modules/platform/outputs.tf`
- Test: `modules/platform/tests/iam.tftest.hcl`

**Interfaces:**
- Consumes: `aws_kms_key.main.arn`, `aws_ecr_repository.mirror` (Tasks 2, 4)
- Produces: **the attachment surface consumed by `analysis/` and by org connectors** —
  `vpc_id`, `private_subnet_ids`, `route_table_id`, `appliance_security_group_id`,
  `appliance_instance_profile_name`, `kms_key_arn`, `data_volume_id`,
  `private_zone_id`, `private_zone_name`, `ecr_repository_urls` (map keyed by image name)

- [ ] **Step 1: Write the failing test**

Create `modules/platform/tests/iam.tftest.hcl`:

```hcl
mock_provider "aws" {}
mock_provider "random" {}

variables {
  name_prefix         = "ir-test"
  budget_alert_emails = ["responder@example.com"]
}

run "instance_role_can_be_managed_by_ssm" {
  command = plan

  assert {
    condition = contains(
      [for a in aws_iam_role_policy_attachment.ssm_core : a.policy_arn],
      "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    )
    error_message = "SSM is the only access path (D6). The instance role must have SSM core."
  }
}

run "instance_role_is_assumable_only_by_ec2" {
  command = plan

  assert {
    condition     = can(regex("ec2\\.amazonaws\\.com", aws_iam_role.appliance.assume_role_policy))
    error_message = "The appliance role must trust the EC2 service and nothing else."
  }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd modules/platform && tofu test`
Expected: FAIL — `Reference to undeclared resource "aws_iam_role" "appliance"`

- [ ] **Step 3: Write the IAM**

Create `modules/platform/iam.tf`:

```hcl
data "aws_iam_policy_document" "appliance_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "appliance" {
  name               = "${var.name_prefix}-appliance"
  assume_role_policy = data.aws_iam_policy_document.appliance_assume.json
  tags               = local.common_tags
}

# SSM Session Manager is the entire access path (D6).
resource "aws_iam_role_policy_attachment" "ssm_core" {
  for_each = toset(["arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"])

  role       = aws_iam_role.appliance.name
  policy_arn = each.value
}

data "aws_iam_policy_document" "appliance" {
  # ECR: pull mirrored images. GetAuthorizationToken cannot be resource-scoped.
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "EcrPull"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [for r in aws_ecr_repository.mirror : r.arn]
  }

  # Decrypt the data volume and the application secrets.
  statement {
    sid       = "KmsUse"
    actions   = ["kms:Decrypt", "kms:DescribeKey", "kms:GenerateDataKey"]
    resources = [aws_kms_key.main.arn]
  }

  # Read the generated secrets written by the analysis layer.
  statement {
    sid       = "SecretsRead"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["arn:aws:secretsmanager:*:*:secret:${var.name_prefix}/*"]
  }

  # Read the image digest manifest published by the mirror pipeline.
  statement {
    sid       = "SsmReadImageDigests"
    actions   = ["ssm:GetParameter", "ssm:GetParametersByPath"]
    resources = ["arn:aws:ssm:*:*:parameter/${var.name_prefix}/images/*"]
  }
}

resource "aws_iam_role_policy" "appliance" {
  name   = "${var.name_prefix}-appliance"
  role   = aws_iam_role.appliance.id
  policy = data.aws_iam_policy_document.appliance.json
}

resource "aws_iam_instance_profile" "appliance" {
  name = "${var.name_prefix}-appliance"
  role = aws_iam_role.appliance.name
  tags = local.common_tags
}
```

- [ ] **Step 4: Write the outputs**

Create `modules/platform/outputs.tf`:

```hcl
# --- Attachment surface (spec 3.3) ---
# An organization wires its own connector (ZPA, Tailscale, TGW) using these
# without editing this module.

output "vpc_id" {
  value       = aws_vpc.main.id
  description = "IR VPC. Attach org-managed connectors here."
}

output "private_subnet_ids" {
  value       = aws_subnet.private[*].id
  description = "Private subnets. No public IPs are assigned."
}

output "route_table_id" {
  value       = aws_route_table.private.id
  description = "Private route table, for connector route propagation."
}

output "appliance_security_group_id" {
  value       = aws_security_group.appliance.id
  description = "Authorize a connector SG on 443 via allowed_ingress_security_group_ids."
}

output "private_zone_id" {
  value       = aws_route53_zone.private.zone_id
  description = "Private hosted zone for the stable Timesketch DNS name."
}

output "private_zone_name" {
  value       = var.private_zone_name
  description = "Zone name, e.g. ir.internal."
}

# --- Consumed by modules/analysis ---

output "kms_key_arn" {
  value       = aws_kms_key.main.arn
  description = "Platform CMK."
}

output "data_volume_id" {
  value       = aws_ebs_volume.data.id
  description = "Persistent data volume. Attached by the analysis layer, owned here."
}

output "data_volume_availability_zone" {
  value       = aws_ebs_volume.data.availability_zone
  description = "The appliance must launch in this AZ to attach the volume."
}

output "appliance_instance_profile_name" {
  value       = aws_iam_instance_profile.appliance.name
  description = "Instance profile granting SSM, ECR pull, and secret read."
}

output "ecr_repository_urls" {
  value       = { for k, r in aws_ecr_repository.mirror : k => r.repository_url }
  description = "Map of image name to ECR repository URL."
}

output "name_prefix" {
  value       = var.name_prefix
  description = "Passed through so the analysis layer names resources consistently."
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd modules/platform && tofu test`
Expected: PASS — all run blocks pass.

- [ ] **Step 6: Commit**

```bash
git add modules/platform/
git commit -m "feat(platform): add appliance IAM role and attachment surface outputs"
```

---

### Task 6: Image mirror pipeline

This module enforces the spec §4.5 invariant's foundation: images are resolved to digests once, and that resolution is the single source of truth.

**Files:**
- Create: `modules/images/variables.tf`, `modules/images/codebuild.tf`, `modules/images/buildspec.yml`, `modules/images/iam.tf`, `modules/images/outputs.tf`
- Test: `modules/images/tests/mirror.tftest.hcl`

**Interfaces:**
- Consumes: `ecr_repository_urls`, `name_prefix`, `kms_key_arn` from `platform`
- Produces: SSM parameters at `/${name_prefix}/images/<name>` each holding a
  `repo@sha256:...` digest reference, read by the appliance at boot

- [ ] **Step 1: Write the failing test**

Create `modules/images/tests/mirror.tftest.hcl`:

```hcl
mock_provider "aws" {}

variables {
  name_prefix = "ir-test"
  ecr_repository_urls = {
    timesketch = "111122223333.dkr.ecr.us-east-1.amazonaws.com/ir-test/timesketch"
    opensearch = "111122223333.dkr.ecr.us-east-1.amazonaws.com/ir-test/opensearch"
    postgres   = "111122223333.dkr.ecr.us-east-1.amazonaws.com/ir-test/postgres"
    redis      = "111122223333.dkr.ecr.us-east-1.amazonaws.com/ir-test/redis"
    nginx      = "111122223333.dkr.ecr.us-east-1.amazonaws.com/ir-test/nginx"
  }
  kms_key_arn = "arn:aws:kms:us-east-1:111122223333:key/abcd"
}

run "mirror_runs_outside_the_vpc" {
  command = plan

  assert {
    condition     = length(aws_codebuild_project.mirror.vpc_config) == 0
    error_message = "The mirror must run outside the IR VPC. CodeBuild's managed network has internet; the IR VPC does not (spec 3.3)."
  }
}

run "image_versions_are_pinned" {
  command = plan

  assert {
    condition     = var.timesketch_version == "20260630"
    error_message = "Timesketch version must match upstream config.env exactly."
  }

  assert {
    condition     = var.opensearch_version == "2.19.5"
    error_message = "OpenSearch version must match upstream config.env exactly."
  }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd modules/images && tofu init -backend=false && tofu test`
Expected: FAIL — `Reference to undeclared resource "aws_codebuild_project" "mirror"`

- [ ] **Step 3: Write the variables**

Create `modules/images/variables.tf`:

```hcl
variable "name_prefix" {
  type        = string
  description = "Prefix from the platform layer."
}

variable "ecr_repository_urls" {
  type        = map(string)
  description = "Map of image name to ECR repository URL, from the platform layer."
}

variable "kms_key_arn" {
  type        = string
  description = "Platform CMK, from the platform layer."
}

# These MUST match https://github.com/google/timesketch/blob/master/docker/release/config.env
# exactly. Drift here is how the spec 4.5 version-parity invariant gets broken.
variable "timesketch_version" {
  type    = string
  default = "20260630"
}

variable "opensearch_version" {
  type    = string
  default = "2.19.5"
}

variable "postgres_version" {
  type    = string
  default = "13.0-alpine"
}

variable "redis_version" {
  type    = string
  default = "7.2.11-alpine"
}

variable "nginx_version" {
  type    = string
  default = "1.25.5-alpine-slim"
}
```

- [ ] **Step 4: Write the buildspec**

Create `modules/images/buildspec.yml`:

```yaml
version: 0.2

phases:
  pre_build:
    commands:
      - aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_REGISTRY"
  build:
    commands:
      # Each entry: <ecr-repo-name> <upstream-image> <ssm-key>
      - |
        set -euo pipefail
        mirror() {
          repo_url="$1"; upstream="$2"; ssm_key="$3"
          echo "Mirroring $upstream -> $repo_url"
          docker pull "$upstream"
          docker tag "$upstream" "$repo_url:$IMAGE_TAG"
          docker push "$repo_url:$IMAGE_TAG"

          # Resolve to an immutable digest and publish it. This is the single
          # source of truth both the appliance and the plaso worker consume.
          digest=$(aws ecr describe-images \
            --repository-name "${repo_url#*/}" \
            --image-ids imageTag="$IMAGE_TAG" \
            --query 'imageDetails[0].imageDigest' --output text)

          aws ssm put-parameter \
            --name "/$NAME_PREFIX/images/$ssm_key" \
            --type String --overwrite \
            --value "$repo_url@$digest"
          echo "$ssm_key -> $repo_url@$digest"
        }

        mirror "$ECR_TIMESKETCH" "us-docker.pkg.dev/osdfir-registry/timesketch/timesketch:$TIMESKETCH_VERSION" timesketch
        mirror "$ECR_OPENSEARCH" "opensearchproject/opensearch:$OPENSEARCH_VERSION"                             opensearch
        mirror "$ECR_POSTGRES"   "postgres:$POSTGRES_VERSION"                                                   postgres
        mirror "$ECR_REDIS"      "redis:$REDIS_VERSION"                                                         redis
        mirror "$ECR_NGINX"      "nginx:$NGINX_VERSION"                                                         nginx
```

- [ ] **Step 5: Write the CodeBuild project and IAM**

Create `modules/images/iam.tf`:

```hcl
data "aws_iam_policy_document" "mirror_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "mirror" {
  name               = "${var.name_prefix}-image-mirror"
  assume_role_policy = data.aws_iam_policy_document.mirror_assume.json
}

data "aws_iam_policy_document" "mirror" {
  statement {
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["*"]
  }

  statement {
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [for url in var.ecr_repository_urls : "arn:aws:ecr:*:*:repository/${split("/", url)[1]}/${split("/", url)[2]}"]
  }

  statement {
    actions   = ["ssm:PutParameter"]
    resources = ["arn:aws:ssm:*:*:parameter/${var.name_prefix}/images/*"]
  }

  statement {
    actions   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "mirror" {
  name   = "${var.name_prefix}-image-mirror"
  role   = aws_iam_role.mirror.id
  policy = data.aws_iam_policy_document.mirror.json
}
```

Create `modules/images/codebuild.tf`:

```hcl
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

resource "aws_codebuild_project" "mirror" {
  name         = "${var.name_prefix}-image-mirror"
  service_role = aws_iam_role.mirror.arn

  # Deliberately NOT attached to the IR VPC. CodeBuild's managed network has
  # internet access; the IR VPC has none (spec 3.3).

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type    = "BUILD_GENERAL1_MEDIUM"
    image           = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true # required to run docker

    environment_variable {
      name  = "NAME_PREFIX"
      value = var.name_prefix
    }
    environment_variable {
      name  = "IMAGE_TAG"
      value = var.timesketch_version
    }
    environment_variable {
      name  = "ECR_REGISTRY"
      value = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${data.aws_region.current.region}.amazonaws.com"
    }
    environment_variable {
      name  = "ECR_TIMESKETCH"
      value = var.ecr_repository_urls["timesketch"]
    }
    environment_variable {
      name  = "ECR_OPENSEARCH"
      value = var.ecr_repository_urls["opensearch"]
    }
    environment_variable {
      name  = "ECR_POSTGRES"
      value = var.ecr_repository_urls["postgres"]
    }
    environment_variable {
      name  = "ECR_REDIS"
      value = var.ecr_repository_urls["redis"]
    }
    environment_variable {
      name  = "ECR_NGINX"
      value = var.ecr_repository_urls["nginx"]
    }
    environment_variable {
      name  = "TIMESKETCH_VERSION"
      value = var.timesketch_version
    }
    environment_variable {
      name  = "OPENSEARCH_VERSION"
      value = var.opensearch_version
    }
    environment_variable {
      name  = "POSTGRES_VERSION"
      value = var.postgres_version
    }
    environment_variable {
      name  = "REDIS_VERSION"
      value = var.redis_version
    }
    environment_variable {
      name  = "NGINX_VERSION"
      value = var.nginx_version
    }
  }

  source {
    type      = "NO_SOURCE"
    buildspec = file("${path.module}/buildspec.yml")
  }
}
```

Create `modules/images/outputs.tf`:

```hcl
output "mirror_project_name" {
  value       = aws_codebuild_project.mirror.name
  description = "Run with: aws codebuild start-build --project-name <this>"
}

output "image_digest_parameter_prefix" {
  value       = "/${var.name_prefix}/images"
  description = "SSM path holding repo@digest references for every mirrored image."
}
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `cd modules/images && tofu test`
Expected: PASS — 3 passed, 0 failed.

- [ ] **Step 7: Commit**

```bash
git add modules/images/
git commit -m "feat(images): add ECR mirror pipeline publishing pinned image digests"
```

---

### Task 7: VPC endpoints with posture gating

**Files:**
- Create: `modules/analysis/variables.tf`, `modules/analysis/endpoints.tf`
- Test: `modules/analysis/tests/posture.tftest.hcl`

**Interfaces:**
- Consumes: platform outputs `vpc_id`, `private_subnet_ids`, `name_prefix`
- Produces: `var.posture`, `local.endpoints_enabled`, `aws_security_group.endpoints.id`

- [ ] **Step 1: Write the failing test**

Create `modules/analysis/tests/posture.tftest.hcl`:

```hcl
mock_provider "aws" {}
mock_provider "random" {}

variables {
  name_prefix                  = "ir-test"
  vpc_id                       = "vpc-123"
  vpc_cidr                     = "10.90.0.0/16"
  private_subnet_ids           = ["subnet-1", "subnet-2"]
  data_volume_id               = "vol-123"
  data_volume_availability_zone = "us-east-1a"
  kms_key_arn                  = "arn:aws:kms:us-east-1:111122223333:key/abcd"
  appliance_instance_profile_name = "ir-test-appliance"
  appliance_security_group_id  = "sg-123"
  private_zone_id              = "Z123"
  private_zone_name            = "ir.internal"
  image_digest_parameter_prefix = "/ir-test/images"
  responders                   = ["responder@example.com"]
}

run "active_creates_interface_endpoints" {
  command = plan

  variables {
    posture = "active"
  }

  assert {
    condition     = length(aws_vpc_endpoint.interface) == 8
    error_message = "Active posture must create all eight interface endpoints."
  }
}

run "dormant_destroys_interface_endpoints" {
  command = plan

  variables {
    posture = "dormant"
  }

  assert {
    condition     = length(aws_vpc_endpoint.interface) == 0
    error_message = "Dormant posture must create no interface endpoints. They bill hourly whether used or not (spec 3.2)."
  }
}

run "posture_rejects_invalid_values" {
  command = plan

  variables {
    posture = "hibernating"
  }

  expect_failures = [var.posture]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd modules/analysis && tofu init -backend=false && tofu test`
Expected: FAIL — `Reference to undeclared resource "aws_vpc_endpoint" "interface"`

- [ ] **Step 3: Write the variables**

Create `modules/analysis/variables.tf`:

```hcl
variable "posture" {
  type        = string
  description = <<-EOT
    active  - appliance running, interface endpoints created
    dormant - appliance stopped, interface endpoints destroyed, data untouched
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
    Appliance size. Because the instance is stopped between incidents and data lives on a
    separate volume, this is a per-incident dial, not a commitment:
      r6i.large    2 vCPU / 16 GiB  - 1-3 responders, modest timelines (default)
      r6i.xlarge   4 vCPU / 32 GiB  - 3-6 responders, sustained ingest
      r6i.2xlarge  8 vCPU / 64 GiB  - large case, multi-TB timelines
  EOT
  default     = "r6i.large"
}

# --- Consumed from the platform layer ---
variable "name_prefix" { type = string }
variable "vpc_id" { type = string }
variable "vpc_cidr" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "data_volume_id" { type = string }
variable "data_volume_availability_zone" { type = string }
variable "kms_key_arn" { type = string }
variable "appliance_instance_profile_name" { type = string }
variable "appliance_security_group_id" { type = string }
variable "private_zone_id" { type = string }
variable "private_zone_name" { type = string }
variable "image_digest_parameter_prefix" { type = string }

variable "responders" {
  type        = list(string)
  description = "Timesketch usernames to provision. Named accounts, never shared (spec 3.4)."
  default     = []
}

variable "tags" {
  type    = map(string)
  default = {}
}
```

- [ ] **Step 4: Write the endpoints**

Create `modules/analysis/endpoints.tf`:

```hcl
data "aws_region" "current" {}

locals {
  common_tags = merge(var.tags, {
    ManagedBy = "opentofu"
    Component = "ir-analysis"
    Posture   = var.posture
  })

  # Destroyed when dormant. These bill hourly whether used or not and are the
  # largest avoidable dormant line item (spec 3.2).
  #
  # Note: ecr.dkr and ecr.api are not sufficient on their own. ECR image layers
  # are fetched from S3, which is why the platform layer creates an S3 gateway
  # endpoint that is always present.
  interface_endpoint_services = var.posture == "active" ? toset([
    "ssm",
    "ssmmessages",
    "ec2messages",
    "ecr.api",
    "ecr.dkr",
    "logs",
    "secretsmanager",
    "kms",
  ]) : toset([])
}

resource "aws_security_group" "endpoints" {
  name        = "${var.name_prefix}-endpoints"
  description = "VPC interface endpoints"
  vpc_id      = var.vpc_id

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-endpoints" })
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_https" {
  security_group_id = aws_security_group.endpoints.id
  cidr_ipv4         = var.vpc_cidr
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "HTTPS from within the VPC"
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_endpoint_services

  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-${each.key}" })
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd modules/analysis && tofu test`
Expected: PASS — 3 passed, 0 failed.

- [ ] **Step 6: Commit**

```bash
git add modules/analysis/
git commit -m "feat(analysis): add posture-gated VPC interface endpoints"
```

---

### Task 8: Generated secrets

**Files:**
- Create: `modules/analysis/secrets.tf`
- Test: `modules/analysis/tests/secrets.tftest.hcl`

**Interfaces:**
- Consumes: `var.name_prefix`, `var.kms_key_arn`, `var.responders`
- Produces: `aws_secretsmanager_secret.postgres`, `aws_secretsmanager_secret.timesketch_secret_key`, `aws_secretsmanager_secret.responder` (map keyed by username)

- [ ] **Step 1: Write the failing test**

Create `modules/analysis/tests/secrets.tftest.hcl`:

```hcl
mock_provider "aws" {}
mock_provider "random" {}

variables {
  name_prefix                     = "ir-test"
  vpc_id                          = "vpc-123"
  vpc_cidr                        = "10.90.0.0/16"
  private_subnet_ids              = ["subnet-1", "subnet-2"]
  data_volume_id                  = "vol-123"
  data_volume_availability_zone   = "us-east-1a"
  kms_key_arn                     = "arn:aws:kms:us-east-1:111122223333:key/abcd"
  appliance_instance_profile_name = "ir-test-appliance"
  appliance_security_group_id     = "sg-123"
  private_zone_id                 = "Z123"
  private_zone_name               = "ir.internal"
  image_digest_parameter_prefix   = "/ir-test/images"
  posture                         = "active"
  responders                      = ["alice", "bob"]
}

run "one_secret_per_responder" {
  command = plan

  assert {
    condition     = length(aws_secretsmanager_secret.responder) == 2
    error_message = "Each responder gets a named account and its own generated password (spec 3.4)."
  }
}

run "secrets_use_the_platform_key" {
  command = plan

  assert {
    condition     = aws_secretsmanager_secret.postgres.kms_key_id == var.kms_key_arn
    error_message = "Secrets must be encrypted with the platform CMK, not an AWS-managed key."
  }
}

run "generated_passwords_are_long" {
  command = plan

  assert {
    condition     = random_password.postgres.length >= 32
    error_message = "Generated passwords must be at least 32 characters."
  }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd modules/analysis && tofu test`
Expected: FAIL — `Reference to undeclared resource "random_password" "postgres"`

- [ ] **Step 3: Write the secrets**

Create `modules/analysis/secrets.tf`:

```hcl
resource "random_password" "postgres" {
  length  = 32
  special = false # Timesketch builds a DB URI from this; avoid escaping hazards
}

resource "random_password" "timesketch_secret_key" {
  length  = 48
  special = true
}

resource "random_password" "responder" {
  for_each = toset(var.responders)

  length  = 32
  special = true
}

resource "aws_secretsmanager_secret" "postgres" {
  name        = "${var.name_prefix}/postgres"
  kms_key_id  = var.kms_key_arn
  description = "PostgreSQL password for the Timesketch appliance"
  tags        = local.common_tags

  # Allow a destroy/recreate cycle without a 7-day wait during development.
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "postgres" {
  secret_id     = aws_secretsmanager_secret.postgres.id
  secret_string = random_password.postgres.result
}

resource "aws_secretsmanager_secret" "timesketch_secret_key" {
  name                    = "${var.name_prefix}/timesketch-secret-key"
  kms_key_id              = var.kms_key_arn
  description             = "Flask SECRET_KEY: signs cookies and provides CSRF protection"
  recovery_window_in_days = 7
  tags                    = local.common_tags
}

resource "aws_secretsmanager_secret_version" "timesketch_secret_key" {
  secret_id     = aws_secretsmanager_secret.timesketch_secret_key.id
  secret_string = random_password.timesketch_secret_key.result
}

resource "aws_secretsmanager_secret" "responder" {
  for_each = toset(var.responders)

  name                    = "${var.name_prefix}/responders/${each.key}"
  kms_key_id              = var.kms_key_arn
  description             = "Timesketch login for ${each.key}"
  recovery_window_in_days = 7
  tags                    = local.common_tags
}

resource "aws_secretsmanager_secret_version" "responder" {
  for_each = toset(var.responders)

  secret_id     = aws_secretsmanager_secret.responder[each.key].id
  secret_string = random_password.responder[each.key].result
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd modules/analysis && tofu test`
Expected: PASS — all run blocks pass.

- [ ] **Step 5: Commit**

```bash
git add modules/analysis/
git commit -m "feat(analysis): generate appliance and responder secrets into Secrets Manager"
```

---

### Task 9: The appliance

The highest-risk task. Three gotchas are handled explicitly and must not be simplified away: NVMe device naming, the idempotent filesystem guard, and `vm.max_map_count`.

**Files:**
- Create: `modules/analysis/appliance.tf`, `modules/analysis/templates/cloud-init.sh.tftpl`, `modules/analysis/templates/docker-compose.yml.tftpl`, `modules/analysis/templates/timesketch.conf.tftpl`
- Test: `modules/analysis/tests/appliance.tftest.hcl`

**Interfaces:**
- Consumes: everything from Tasks 7 and 8, plus all platform outputs
- Produces: `aws_instance.appliance.id`, `aws_instance.appliance.private_ip`, `aws_ec2_instance_state.appliance`

- [ ] **Step 1: Write the failing test**

Create `modules/analysis/tests/appliance.tftest.hcl`:

```hcl
mock_provider "aws" {}
mock_provider "random" {}

variables {
  name_prefix                     = "ir-test"
  vpc_id                          = "vpc-123"
  vpc_cidr                        = "10.90.0.0/16"
  private_subnet_ids              = ["subnet-1", "subnet-2"]
  data_volume_id                  = "vol-123"
  data_volume_availability_zone   = "us-east-1a"
  kms_key_arn                     = "arn:aws:kms:us-east-1:111122223333:key/abcd"
  appliance_instance_profile_name = "ir-test-appliance"
  appliance_security_group_id     = "sg-123"
  private_zone_id                 = "Z123"
  private_zone_name               = "ir.internal"
  image_digest_parameter_prefix   = "/ir-test/images"
  responders                      = ["alice"]
}

run "appliance_has_no_public_ip" {
  command = plan
  variables { posture = "active" }

  assert {
    condition     = aws_instance.appliance.associate_public_ip_address == false
    error_message = "No public ingress (D6). The appliance must never have a public IP."
  }
}

run "active_posture_runs_the_instance" {
  command = plan
  variables { posture = "active" }

  assert {
    condition     = aws_ec2_instance_state.appliance.state == "running"
    error_message = "Active posture must run the appliance."
  }
}

run "dormant_posture_stops_but_does_not_destroy" {
  command = plan
  variables { posture = "dormant" }

  assert {
    condition     = aws_ec2_instance_state.appliance.state == "stopped"
    error_message = "Dormant posture stops the appliance."
  }

  assert {
    condition     = aws_instance.appliance.id != null
    error_message = "Dormant must STOP the instance, never destroy it (spec 3.2)."
  }
}

run "default_instance_type_is_r6i_large" {
  command = plan
  variables { posture = "active" }

  assert {
    condition     = aws_instance.appliance.instance_type == "r6i.large"
    error_message = "Default must be r6i.large (spec 3.4). Larger defaults cost ~$368/month."
  }
}

run "root_volume_is_encrypted" {
  command = plan
  variables { posture = "active" }

  assert {
    condition     = aws_instance.appliance.root_block_device[0].encrypted == true
    error_message = "Root volume must be encrypted with the platform CMK."
  }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd modules/analysis && tofu test`
Expected: FAIL — `Reference to undeclared resource "aws_instance" "appliance"`

- [ ] **Step 3: Write the Timesketch config template**

Create `modules/analysis/templates/timesketch.conf.tftpl`:

```python
# Managed by OpenTofu. Do not edit on the instance.

SECRET_KEY = '${secret_key}'

SQLALCHEMY_DATABASE_URI = 'postgresql://timesketch:${postgres_password}@postgres/timesketch'

OPENSEARCH_HOST = 'opensearch'
OPENSEARCH_PORT = 9200

UPLOAD_ENABLED = True
UPLOAD_FOLDER = '/usr/share/timesketch/upload'

CELERY_BROKER_URL = 'redis://redis:6379'
CELERY_RESULT_BACKEND = 'redis://redis:6379'

# No federation in Phase 1. Access is SSM tunnel + local accounts (D6).
SSO_ENABLED = False
GOOGLE_OIDC_ENABLED = False

# Break-glass: local database accounts keep working even if OIDC is enabled later.
LOCAL_AUTH_ALLOWED_USERS = [${local_auth_allowed_users}]

AUTO_SKETCH_ANALYZERS = []
```

- [ ] **Step 4: Write the compose template**

Create `modules/analysis/templates/docker-compose.yml.tftpl`:

```yaml
# Managed by OpenTofu. Images are digest-pinned (spec 4.5).
services:
  opensearch:
    image: ${opensearch_image}
    restart: always
    environment:
      - discovery.type=single-node
      - bootstrap.memory_lock=true
      - "OPENSEARCH_JAVA_OPTS=-Xms${opensearch_heap_gb}g -Xmx${opensearch_heap_gb}g"
      - DISABLE_INSTALL_DEMO_CONFIG=true
      - DISABLE_SECURITY_PLUGIN=true
    ulimits:
      memlock: { soft: -1, hard: -1 }
      nofile: { soft: 65536, hard: 65536 }
    volumes:
      - /mnt/data/opensearch:/usr/share/opensearch/data

  postgres:
    image: ${postgres_image}
    restart: always
    environment:
      - POSTGRES_USER=timesketch
      - POSTGRES_PASSWORD=${postgres_password}
      - POSTGRES_DB=timesketch
    volumes:
      - /mnt/data/postgresql:/var/lib/postgresql/data

  redis:
    image: ${redis_image}
    restart: always

  timesketch-web:
    image: ${timesketch_image}
    command: timesketch-web
    restart: always
    ports:
      - "127.0.0.1:5000:5000"
    environment:
      - NUM_WSGI_WORKERS=${num_wsgi_workers}
      - WSGI_WORKER_CLASS=gthread
      - NUM_WSGI_THREADS=4
    volumes:
      - /opt/timesketch/etc:/etc/timesketch
      - /mnt/data/upload:/usr/share/timesketch/upload
    depends_on: [opensearch, postgres, redis]

  timesketch-worker:
    image: ${timesketch_image}
    command: timesketch-worker
    restart: always
    environment:
      - WORKER_LOG_LEVEL=info
    volumes:
      - /opt/timesketch/etc:/etc/timesketch
      - /mnt/data/upload:/usr/share/timesketch/upload
    depends_on: [opensearch, postgres, redis]
```

- [ ] **Step 5: Write the cloud-init template**

Create `modules/analysis/templates/cloud-init.sh.tftpl`:

```bash
#!/bin/bash
set -euxo pipefail

# --- GOTCHA 1: OpenSearch refuses to start without this. ---
# The default vm.max_map_count is 65530; OpenSearch requires 262144.
# Persist it so it survives the stop/start cycles that dormancy performs.
echo 'vm.max_map_count=262144' > /etc/sysctl.d/99-opensearch.conf
sysctl -p /etc/sysctl.d/99-opensearch.conf

dnf install -y docker
systemctl enable --now docker
DOCKER_COMPOSE_DIR=/usr/local/lib/docker/cli-plugins
mkdir -p "$DOCKER_COMPOSE_DIR"
# docker-compose-plugin is not in the AL2023 repos; the binary is fetched by the
# mirror pipeline into S3 in a later phase. For Phase 1, use the dnf package.
dnf install -y docker-compose-plugin || true

# --- GOTCHA 2: On Nitro instances (r6i), an EBS volume attached as /dev/sdf
# appears to the OS as an NVMe device with an unpredictable number. Resolve it
# by volume ID instead of guessing a device path. ---
VOLUME_ID_NODASH=$(echo "${data_volume_id}" | tr -d '-')
DEVICE=""
for _ in $(seq 1 30); do
  for candidate in /dev/nvme*n1; do
    [ -e "$candidate" ] || continue
    if nvme id-ctrl -v "$candidate" 2>/dev/null | grep -q "$VOLUME_ID_NODASH"; then
      DEVICE="$candidate"
      break 2
    fi
  done
  sleep 2
done
if [ -z "$DEVICE" ]; then
  echo "FATAL: could not locate data volume ${data_volume_id}" >&2
  exit 1
fi

# --- GOTCHA 3: This must be idempotent. cloud-init runs on every boot, and
# dormancy stops and starts this instance repeatedly. Formatting unconditionally
# would destroy all evidence on the second activation. ---
if ! blkid "$DEVICE"; then
  echo "No filesystem on $DEVICE - first boot, creating one"
  mkfs.ext4 -L irdata "$DEVICE"
fi

mkdir -p /mnt/data
grep -q "LABEL=irdata" /etc/fstab || echo "LABEL=irdata /mnt/data ext4 defaults,nofail 0 2" >> /etc/fstab
mount -a
mkdir -p /mnt/data/opensearch /mnt/data/postgresql /mnt/data/upload

# OpenSearch runs as uid 1000 inside its container.
chown -R 1000:1000 /mnt/data/opensearch
chmod 700 /mnt/data/postgresql

# --- Resolve digest-pinned images (spec 4.5 invariant) ---
REGION="${region}"
get_image() {
  aws ssm get-parameter --region "$REGION" \
    --name "${image_digest_parameter_prefix}/$1" \
    --query 'Parameter.Value' --output text
}

aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "${ecr_registry}"

mkdir -p /opt/timesketch/etc
cat > /opt/timesketch/etc/timesketch.conf <<'TSCONF'
${timesketch_conf}
TSCONF

cat > /opt/timesketch/docker-compose.yml <<COMPOSE
${docker_compose}
COMPOSE

cd /opt/timesketch
docker compose up -d

# --- Provision responder accounts (idempotent) ---
until docker compose exec -T timesketch-web tsctl list-users >/dev/null 2>&1; do
  echo "waiting for timesketch-web"
  sleep 5
done

%{ for user in responders ~}
if ! docker compose exec -T timesketch-web tsctl list-users | grep -qx "${user}"; then
  PW=$(aws secretsmanager get-secret-value --region "$REGION" \
    --secret-id "${name_prefix}/responders/${user}" \
    --query SecretString --output text)
  docker compose exec -T timesketch-web tsctl create-user "${user}" --password "$PW"
fi
%{ endfor ~}

echo "appliance ready"
```

- [ ] **Step 6: Write the appliance**

Create `modules/analysis/appliance.tf`:

```hcl
data "aws_caller_identity" "current" {}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-6.1-x86_64"]
  }
}

data "aws_ssm_parameter" "image" {
  for_each = toset(["timesketch", "opensearch", "postgres", "redis", "nginx"])
  name     = "${var.image_digest_parameter_prefix}/${each.key}"
}

locals {
  # Upstream rule from config.env: RAM / 2, capped at 32GB.
  instance_memory_gb = {
    "r6i.large"   = 16
    "r6i.xlarge"  = 32
    "r6i.2xlarge" = 64
    "r6i.4xlarge" = 128
  }

  instance_vcpus = {
    "r6i.large"   = 2
    "r6i.xlarge"  = 4
    "r6i.2xlarge" = 8
    "r6i.4xlarge" = 16
  }

  opensearch_heap_gb = min(32, floor(lookup(local.instance_memory_gb, var.instance_type, 16) / 2))

  # Upstream rule from config.env: (num cores * 2) + 1
  num_wsgi_workers = (lookup(local.instance_vcpus, var.instance_type, 2) * 2) + 1

  ecr_registry = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${data.aws_region.current.region}.amazonaws.com"

  timesketch_conf = templatefile("${path.module}/templates/timesketch.conf.tftpl", {
    secret_key               = random_password.timesketch_secret_key.result
    postgres_password        = random_password.postgres.result
    local_auth_allowed_users = join(", ", [for u in var.responders : "'${u}'"])
  })

  docker_compose = templatefile("${path.module}/templates/docker-compose.yml.tftpl", {
    timesketch_image   = data.aws_ssm_parameter.image["timesketch"].value
    opensearch_image   = data.aws_ssm_parameter.image["opensearch"].value
    postgres_image     = data.aws_ssm_parameter.image["postgres"].value
    redis_image        = data.aws_ssm_parameter.image["redis"].value
    postgres_password  = random_password.postgres.result
    opensearch_heap_gb = local.opensearch_heap_gb
    num_wsgi_workers   = local.num_wsgi_workers
  })
}

resource "aws_instance" "appliance" {
  ami           = data.aws_ami.al2023.id
  instance_type = var.instance_type

  # Must match the data volume's AZ - EBS attaches only within one AZ.
  subnet_id = var.private_subnet_ids[0]

  iam_instance_profile   = var.appliance_instance_profile_name
  vpc_security_group_ids = [var.appliance_security_group_id]

  associate_public_ip_address = false

  root_block_device {
    volume_size = 50
    volume_type = "gp3"
    encrypted   = true
    kms_key_id  = var.kms_key_arn
  }

  metadata_options {
    http_tokens   = "required" # IMDSv2 only
    http_endpoint = "enabled"
  }

  user_data = templatefile("${path.module}/templates/cloud-init.sh.tftpl", {
    data_volume_id                = var.data_volume_id
    region                        = data.aws_region.current.region
    ecr_registry                  = local.ecr_registry
    image_digest_parameter_prefix = var.image_digest_parameter_prefix
    timesketch_conf               = local.timesketch_conf
    docker_compose                = local.docker_compose
    responders                    = var.responders
    name_prefix                   = var.name_prefix
  })

  # Re-running cloud-init on a changed template requires a replacement, which
  # would orphan nothing - the data volume is in the platform layer.
  user_data_replace_on_change = true

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-appliance" })
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = var.data_volume_id
  instance_id = aws_instance.appliance.id

  # Without this, destroying the analysis layer hangs waiting for a graceful
  # detach that a stopped instance will never perform.
  force_detach = true
}

# Dormancy stops the instance; it never destroys it (spec 3.2).
resource "aws_ec2_instance_state" "appliance" {
  instance_id = aws_instance.appliance.id
  state       = var.posture == "active" ? "running" : "stopped"
}

resource "aws_route53_record" "timesketch" {
  zone_id = var.private_zone_id
  name    = "timesketch.${var.private_zone_name}"
  type    = "A"
  ttl     = 60
  records = [aws_instance.appliance.private_ip]
}
```

Create `modules/analysis/outputs.tf`:

```hcl
output "appliance_instance_id" {
  value       = aws_instance.appliance.id
  description = "Use with: aws ssm start-session --target <this>"
}

output "timesketch_private_dns" {
  value       = aws_route53_record.timesketch.name
  description = "Stable name for org-managed connector application segments."
}

output "posture" {
  value       = var.posture
  description = "Current posture."
}

output "ssm_port_forward_command" {
  value = join(" ", [
    "aws ssm start-session",
    "--target ${aws_instance.appliance.id}",
    "--document-name AWS-StartPortForwardingSession",
    "--parameters '{\"portNumber\":[\"5000\"],\"localPortNumber\":[\"5000\"]}'",
  ])
  description = "Run this, then open http://localhost:5000"
}
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `cd modules/analysis && tofu test`
Expected: PASS — all run blocks across all three test files pass.

- [ ] **Step 8: Commit**

```bash
git add modules/analysis/
git commit -m "feat(analysis): add Timesketch appliance with posture-driven instance state"
```

---

### Task 10: Example environment and acceptance test

**Files:**
- Create: `envs/example/platform/main.tf`, `envs/example/images/main.tf`, `envs/example/analysis/main.tf`, `envs/example/README.md`
- Create: `docs/acceptance/phase-1.md`

**Interfaces:**
- Consumes: all three modules
- Produces: a working reference deployment and the documented acceptance run

- [ ] **Step 1: Write the platform environment**

Create `envs/example/platform/main.tf`:

```hcl
terraform {
  required_version = "~> 1.12.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.64.0"
    }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "budget_alert_emails" {
  type = list(string)
}

module "platform" {
  source = "../../../modules/platform"

  name_prefix         = "ir-dev"
  budget_alert_emails = var.budget_alert_emails
  monthly_budget_usd  = 200
  data_volume_gb      = 100 # smaller for development

  tags = {
    Environment = "development"
  }
}

output "platform" {
  value = module.platform
}
```

- [ ] **Step 2: Write the images environment**

Create `envs/example/images/main.tf`:

```hcl
terraform {
  required_version = "~> 1.12.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.64.0"
    }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "platform_state_path" {
  type        = string
  description = "Path to the platform layer's state file."
  default     = "../platform/terraform.tfstate"
}

data "terraform_remote_state" "platform" {
  backend = "local"
  config  = { path = var.platform_state_path }
}

module "images" {
  source = "../../../modules/images"

  name_prefix         = data.terraform_remote_state.platform.outputs.platform.name_prefix
  ecr_repository_urls = data.terraform_remote_state.platform.outputs.platform.ecr_repository_urls
  kms_key_arn         = data.terraform_remote_state.platform.outputs.platform.kms_key_arn
}

output "mirror_project_name" {
  value = module.images.mirror_project_name
}
```

- [ ] **Step 3: Write the analysis environment**

Create `envs/example/analysis/main.tf`:

```hcl
terraform {
  required_version = "~> 1.12.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.64.0"
    }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "posture" {
  type    = string
  default = "dormant"
}

variable "responders" {
  type    = list(string)
  default = []
}

data "terraform_remote_state" "platform" {
  backend = "local"
  config  = { path = "../platform/terraform.tfstate" }
}

locals {
  p = data.terraform_remote_state.platform.outputs.platform
}

module "analysis" {
  source = "../../../modules/analysis"

  posture    = var.posture
  responders = var.responders

  name_prefix                     = local.p.name_prefix
  vpc_id                          = local.p.vpc_id
  vpc_cidr                        = "10.90.0.0/16"
  private_subnet_ids              = local.p.private_subnet_ids
  data_volume_id                  = local.p.data_volume_id
  data_volume_availability_zone   = local.p.data_volume_availability_zone
  kms_key_arn                     = local.p.kms_key_arn
  appliance_instance_profile_name = local.p.appliance_instance_profile_name
  appliance_security_group_id     = local.p.appliance_security_group_id
  private_zone_id                 = local.p.private_zone_id
  private_zone_name               = local.p.private_zone_name
  image_digest_parameter_prefix   = "/${local.p.name_prefix}/images"
}

output "ssm_port_forward_command" {
  value = module.analysis.ssm_port_forward_command
}
```

- [ ] **Step 4: Write the acceptance test document**

Create `docs/acceptance/phase-1.md`:

```markdown
# Phase 1 Acceptance

Phase 1 is done when this runs green end to end. Spec §9: *"Timesketch reachable over SSM;
dormant/active cycle preserves data."*

**Cost warning:** this creates real resources. Run `make dormant` when finished, and destroy
the analysis layer if you are stepping away for more than a day.

## 1. Apply the platform layer

    cd envs/example/platform
    tofu init && tofu apply -var='budget_alert_emails=["you@example.com"]'

Confirm the budget alarm exists before continuing. Idle cost is the failure mode it guards.

## 2. Mirror the images

    cd ../images && tofu init && tofu apply
    aws codebuild start-build --project-name "$(tofu output -raw mirror_project_name)"

Wait for SUCCEEDED, then verify every digest landed:

    aws ssm get-parameters-by-path --path /ir-dev/images --query 'Parameters[].[Name,Value]' --output table

Expected: five parameters, each ending in `@sha256:...`. **A tag reference here is a defect** —
spec §4.5 requires digests.

## 3. Activate

    cd ../analysis && tofu init
    tofu apply -var='posture=active' -var='responders=["alice"]'

## 4. Reach Timesketch

    $(cd envs/example/analysis && tofu output -raw ssm_port_forward_command)

Open `http://localhost:5000`. Log in as `alice` with:

    aws secretsmanager get-secret-value --secret-id ir-dev/responders/alice --query SecretString --output text

**Checkpoint:** the Timesketch UI loads and accepts the login.

## 5. Create state worth preserving

In the UI, create a sketch named `acceptance-check`.

## 6. Go dormant

    tofu apply -var='posture=dormant'

Verify:

    aws ec2 describe-instances --filters "Name=tag:Name,Values=ir-dev-appliance" \
      --query 'Reservations[].Instances[].State.Name' --output text
    # Expected: stopped

    aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=<vpc-id>" \
      --query 'VpcEndpoints[?VpcEndpointType==`Interface`]' --output text
    # Expected: empty

    aws ec2 describe-volumes --volume-ids <data-volume-id> \
      --query 'Volumes[].State' --output text
    # Expected: in-use  (attached to the stopped instance, NOT deleted)

## 7. Reactivate and confirm the data survived

    tofu apply -var='posture=active' -var='responders=["alice"]'

Re-run the port-forward, log in, and confirm the `acceptance-check` sketch is still there.

**This is the test that matters.** If the sketch survived, the dormancy design works. If the
volume was reformatted, the idempotency guard in `cloud-init.sh.tftpl` is broken — that is the
single highest-risk defect in Phase 1.

## 8. Clean up

    tofu apply -var='posture=dormant'
```

- [ ] **Step 5: Add the posture convenience targets**

Append to `Makefile`:

```makefile
ANALYSIS_ENV := envs/example/analysis

.PHONY: dormant active

dormant:
	cd $(ANALYSIS_ENV) && tofu apply -var='posture=dormant'

active:
	cd $(ANALYSIS_ENV) && tofu apply -var='posture=active'
```

- [ ] **Step 6: Verify the whole repo checks out**

Run: `make check`
Expected: fmt, validate, lint, and all module tests PASS.

- [ ] **Step 7: Commit**

```bash
git add envs/ docs/acceptance/ Makefile
git commit -m "feat: add example environment and Phase 1 acceptance procedure"
```

- [ ] **Step 8: Run the acceptance test**

Follow `docs/acceptance/phase-1.md` against the development account. Record the result in the
PR. Phase 1 is not complete until step 7 of that document passes.

---

## Self-Review

**Spec coverage for Phase 1** (spec §9 row 1: platform layer, appliance, dormancy toggle):

| Spec section | Task |
|---|---|
| §3.1 layering, data volume in permanent layer | 4 |
| §3.2 posture variable, endpoint teardown, instance stop | 7, 9 |
| §3.3 no egress, S3 gateway endpoint, attachment surface | 3, 5 |
| §3.4 appliance, r6i.large default, responder accounts, `LOCAL_AUTH_ALLOWED_USERS` | 8, 9 |
| §3.5 SSM as sole access path | 5, 9, 10 |
| §4.5 digest pinning foundation | 6, 9 |
| §5.2.2 budget alarm before first apply, `name_prefix` | 2, 3 |
| §8 CI: fmt, validate, tflint, `tofu test` | 1 |

Deferred to later phases by design, not omission: S3 evidence buckets, DynamoDB case store, and
CloudTrail (Phase 2); Batch, Step Functions, and the plaso worker image (Phase 3) — which is
where the §4.5 parity *assertion* lands, since there is no worker image to compare against until
then; Snyk IaC scanning (add with Phase 2's first AWS data resources).

**Type consistency:** platform output names match analysis variable names exactly
(`data_volume_availability_zone`, `appliance_instance_profile_name`,
`image_digest_parameter_prefix`). The `image_digest_parameter_prefix` value `/${name_prefix}/images`
is produced identically by `modules/images/outputs.tf` and consumed in `modules/analysis`.

**Known risk, flagged for the implementer:** Task 9's NVMe device resolution depends on
`nvme id-ctrl` output containing the volume ID without dashes. Verify on a real instance during
the acceptance run; if it fails, the fallback is
`/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_vol<id-without-dashes>`.
