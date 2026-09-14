# A stable name matters because connector application segments should reference
# a name that survives instance replacement, not an IP that does not (spec 3.3).
resource "aws_route53_zone" "private" {
  name = var.private_zone_name

  vpc {
    vpc_id = aws_vpc.main.id
  }

  tags = local.common_tags
}
