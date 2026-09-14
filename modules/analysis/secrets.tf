resource "random_password" "postgres" {
  length = 32

  # Timesketch builds a PostgreSQL URI from this value. Special characters would
  # need escaping and silently break the connection string.
  special = false
}

resource "random_password" "timesketch_secret_key" {
  length  = 48
  special = true
}

# Named accounts, never shared. Timesketch attributes every comment, tag, star,
# and saved search to a user; a shared login destroys that attribution, which
# matters if the investigation is later scrutinised (spec 3.4).
resource "random_password" "responder" {
  for_each = toset(var.responders)

  length  = 32
  special = true
}

resource "aws_secretsmanager_secret" "postgres" {
  name        = "${var.name_prefix}/postgres"
  kms_key_id  = var.kms_key_arn
  description = "PostgreSQL password for the Timesketch appliance"

  # Allow a destroy/recreate cycle without a 30-day name collision during
  # development. Secrets here are regenerable; the evidence they protect is not
  # stored in them.
  recovery_window_in_days = 7

  tags = local.common_tags
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

  tags = local.common_tags
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

  tags = local.common_tags
}

resource "aws_secretsmanager_secret_version" "responder" {
  for_each = toset(var.responders)

  secret_id     = aws_secretsmanager_secret.responder[each.key].id
  secret_string = random_password.responder[each.key].result
}
