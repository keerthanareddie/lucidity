# ── VPC Module ────────────────────────────────────────────────────────────────
# Production-grade VPC with:
#   - Public subnets  (NAT Gateways, ALB)
#   - Private subnets (EKS nodes — never directly reachable)
#   - Single NAT Gateway (cost-optimised for assignment; use one per AZ in real prod)
#   - VPC Flow Logs   → CloudWatch for network forensics
#   - NACLs           → subnet-level defence in depth

terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

# ── VPC ───────────────────────────────────────────────────────────────────────
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true   # required for EKS
  enable_dns_support   = true

  tags = merge(var.tags, {
    Name = "${var.name}-vpc"
    # EKS needs these tags on the VPC
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  })
}

# ── Internet Gateway ──────────────────────────────────────────────────────────
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = merge(var.tags, { Name = "${var.name}-igw" })
}

# ── Public Subnets ────────────────────────────────────────────────────────────
resource "aws_subnet" "public" {
  count             = length(var.availability_zones)
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index)
  availability_zone = var.availability_zones[count.index]

  # ALB nodes need public IPs
  map_public_ip_on_launch = true

  tags = merge(var.tags, {
    Name = "${var.name}-public-${var.availability_zones[count.index]}"
    # EKS needs these tags so it can create internet-facing load balancers
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                    = "1"
  })
}

# ── Private Subnets ───────────────────────────────────────────────────────────
resource "aws_subnet" "private" {
  count             = length(var.availability_zones)
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index + length(var.availability_zones))
  availability_zone = var.availability_zones[count.index]

  # EKS nodes never get public IPs
  map_public_ip_on_launch = false

  tags = merge(var.tags, {
    Name = "${var.name}-private-${var.availability_zones[count.index]}"
    # EKS needs these for internal load balancers
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
    "kubernetes.io/role/internal-elb"           = "1"
  })
}

# ── Elastic IP for NAT Gateway ────────────────────────────────────────────────
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = merge(var.tags, { Name = "${var.name}-nat-eip" })
}

# ── NAT Gateway (single for cost — use one per AZ in real prod) ───────────────
resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id   # lives in public subnet
  depends_on    = [aws_internet_gateway.main]
  tags          = merge(var.tags, { Name = "${var.name}-nat" })
}

# ── Route Tables ──────────────────────────────────────────────────────────────
# Public route table → IGW
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = merge(var.tags, { Name = "${var.name}-public-rt" })
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Private route table → NAT Gateway
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }
  tags = merge(var.tags, { Name = "${var.name}-private-rt" })
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ── NACLs — Defence in Depth ──────────────────────────────────────────────────
# Public NACL — allows HTTP/HTTPS + ephemeral return traffic
resource "aws_network_acl" "public" {
  vpc_id     = aws_vpc.main.id
  subnet_ids = aws_subnet.public[*].id

  # Inbound
  ingress {
    rule_no    = 100; protocol = "tcp"; action = "allow"
    cidr_block = "0.0.0.0/0"; from_port = 443; to_port = 443
  }
  ingress {
    rule_no    = 110; protocol = "tcp"; action = "allow"
    cidr_block = "0.0.0.0/0"; from_port = 80; to_port = 80
  }
  ingress {
    # Ephemeral return traffic (stateless NACL requirement)
    rule_no    = 120; protocol = "tcp"; action = "allow"
    cidr_block = "0.0.0.0/0"; from_port = 1024; to_port = 65535
  }

  # Outbound — allow all (EKS nodes pull images, etc.)
  egress {
    rule_no    = 100; protocol = "-1"; action = "allow"
    cidr_block = "0.0.0.0/0"; from_port = 0; to_port = 0
  }

  tags = merge(var.tags, { Name = "${var.name}-public-nacl" })
}

# Private NACL — only allows traffic from within the VPC + return traffic
resource "aws_network_acl" "private" {
  vpc_id     = aws_vpc.main.id
  subnet_ids = aws_subnet.private[*].id

  # Inbound from VPC CIDR only
  ingress {
    rule_no    = 100; protocol = "tcp"; action = "allow"
    cidr_block = var.vpc_cidr; from_port = 0; to_port = 65535
  }
  # Ephemeral return traffic from internet (for outbound calls via NAT)
  ingress {
    rule_no    = 110; protocol = "tcp"; action = "allow"
    cidr_block = "0.0.0.0/0"; from_port = 1024; to_port = 65535
  }

  # Outbound — allow all (NAT handles external restrictions)
  egress {
    rule_no    = 100; protocol = "-1"; action = "allow"
    cidr_block = "0.0.0.0/0"; from_port = 0; to_port = 0
  }

  tags = merge(var.tags, { Name = "${var.name}-private-nacl" })
}

# ── VPC Flow Logs → CloudWatch ────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "vpc_flow_logs" {
  name              = "/aws/vpc/${var.name}/flow-logs"
  retention_in_days = 30
  tags              = var.tags
}

resource "aws_iam_role" "vpc_flow_logs" {
  name = "${var.name}-vpc-flow-logs-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy" "vpc_flow_logs" {
  name = "${var.name}-vpc-flow-logs-policy"
  role = aws_iam_role.vpc_flow_logs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup", "logs:CreateLogStream",
        "logs:PutLogEvents", "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ]
      Resource = "*"
    }]
  })
}

resource "aws_flow_log" "main" {
  vpc_id          = aws_vpc.main.id
  traffic_type    = "ALL"
  iam_role_arn    = aws_iam_role.vpc_flow_logs.arn
  log_destination = aws_cloudwatch_log_group.vpc_flow_logs.arn
  tags            = merge(var.tags, { Name = "${var.name}-flow-log" })
}
