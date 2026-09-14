# The keystone of spec 3.1.
#
# This volume lives in the permanent platform layer, not the toggleable analysis
# layer, so that `tofu destroy` against modules/analysis loses no warm data.
# Indices and evidence sit on the other side of that boundary. It is also what
# makes a colder dormancy tier available later at no additional design cost.
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
