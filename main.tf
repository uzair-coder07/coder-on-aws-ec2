# ============================================================================
# Provider Configuration
# ============================================================================

terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ============================================================================
# Variables
# ============================================================================

variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "EC2 instance type (2vCPU, 4GB RAM)"
  type        = string
  default     = "t3.medium"
}

variable "key_name" {
  description = "Name of the AWS key pair to use for SSH access. If not provided, a new key pair will be created."
  type        = string
  default     = ""
}

variable "public_key_path" {
  description = "Path to the public key file (used if key_name is not provided)"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "postgres_username" {
  description = "PostgreSQL username"
  type        = string
  default     = "coder"
}

variable "postgres_password" {
  description = "PostgreSQL password"
  type        = string
  default     = "coder"
  sensitive   = true
}

variable "postgres_database" {
  description = "PostgreSQL database name"
  type        = string
  default     = "coder"
}

variable "coder_version" {
  description = "Coder version to install"
  type        = string
  default     = "latest"
}

variable "project_name" {
  description = "Project name for resource tagging"
  type        = string
  default     = "coder-simple"
}

variable "allowed_ssh_cidr" {
  description = "CIDR block allowed to SSH into instances (default: anywhere)"
  type        = string
  default     = "0.0.0.0/0"
}

variable "root_volume_size" {
  description = "Size of the root EBS volume in GB"
  type        = number
  default     = 25
}

variable "root_volume_type" {
  description = "Type of the root EBS volume (gp3, gp2, io1, io2)"
  type        = string
  default     = "gp3"
}

# ============================================================================
# Data Sources
# ============================================================================

# Get the default VPC
data "aws_vpc" "default" {
  default = true
}

# Get default subnet in the first availability zone
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Get the latest Ubuntu 22.04 LTS AMI
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-20251022"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ============================================================================
# Key Pair
# ============================================================================

# Create a new key pair if key_name is not provided
resource "aws_key_pair" "coder" {
  count      = var.key_name == "" ? 1 : 0
  key_name   = "${var.project_name}-key"
  public_key = file(pathexpand(var.public_key_path))

  tags = {
    Name    = "${var.project_name}-key"
    Project = var.project_name
  }
}

# Use either the provided key_name or the newly created key
locals {
  key_name = var.key_name != "" ? var.key_name : aws_key_pair.coder[0].key_name
}

# ============================================================================
# Security Groups
# ============================================================================

# Security Group for Coder (must be created first so Postgres SG can reference it)
resource "aws_security_group" "coder" {
  name        = "${var.project_name}-coder-sg"
  description = "Security group for Coder application"
  vpc_id      = data.aws_vpc.default.id

  # Allow HTTP traffic from anywhere
  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow HTTPS traffic from anywhere
  ingress {
    description = "HTTPS from anywhere"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow SSH traffic for administration
  ingress {
    description = "SSH from allowed CIDR"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  # Allow Coder's default port (7080) from anywhere
  ingress {
    description = "Coder HTTP from anywhere"
    from_port   = 7080
    to_port     = 7080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow all outbound traffic
  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-coder-sg"
    Project = var.project_name
  }
}

# Security Group for PostgreSQL
resource "aws_security_group" "postgres" {
  name        = "${var.project_name}-postgres-sg"
  description = "Security group for PostgreSQL database"
  vpc_id      = data.aws_vpc.default.id

  # Allow PostgreSQL traffic ONLY from Coder security group
  ingress {
    description     = "PostgreSQL from Coder only"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.coder.id]
  }

  # Allow SSH traffic for administration
  ingress {
    description = "SSH from allowed CIDR"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  # Allow all outbound traffic (for package installation)
  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-postgres-sg"
    Project = var.project_name
  }
}

# ============================================================================
# EC2 Instances
# ============================================================================

# PostgreSQL EC2 Instance (public but restricted by security group)
resource "aws_instance" "postgres" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = tolist(data.aws_subnets.default.ids)[0]
  vpc_security_group_ids = [aws_security_group.postgres.id]
  key_name               = local.key_name

  # Public IP assigned (default subnet behavior)
  associate_public_ip_address = true

  # Root EBS volume configuration
  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = var.root_volume_type
    delete_on_termination = true
    encrypted             = true
    
    tags = {
      Name    = "${var.project_name}-postgres-root-volume"
      Project = var.project_name
    }
  }

  # User data script to install and configure PostgreSQL
  user_data = <<-EOF
              #!/bin/bash
              set -e
              
              # Log all output to a file for debugging
              exec > >(tee -a /var/log/user-data.log)
              exec 2>&1
              
              echo "Starting PostgreSQL installation at $(date)"
              
              # Update system
              apt-get update
              apt-get upgrade -y
              
              # Install PostgreSQL
              apt-get install -y postgresql postgresql-contrib
              
              # Wait for PostgreSQL to start
              sleep 10
              
              # Configure PostgreSQL to listen on all interfaces
              echo "listen_addresses = '*'" >> /etc/postgresql/*/main/postgresql.conf
              
              # Configure pg_hba.conf to allow connections from VPC
              # Using the default VPC CIDR
              echo "host    all    all    0.0.0.0/0    md5" >> /etc/postgresql/*/main/pg_hba.conf
              
              # Restart PostgreSQL
              systemctl restart postgresql
              
              # Wait for PostgreSQL to be ready
              sleep 5
              
              # Create database and user
              sudo -u postgres psql -c "CREATE USER ${var.postgres_username} WITH PASSWORD '${var.postgres_password}';" || true
              sudo -u postgres psql -c "CREATE DATABASE ${var.postgres_database} OWNER ${var.postgres_username};" || true
              sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE ${var.postgres_database} TO ${var.postgres_username};" || true
              
              # Ensure PostgreSQL starts on boot
              systemctl enable postgresql
              
              echo "PostgreSQL installation and configuration complete at $(date)"
              EOF

  tags = {
    Name    = "${var.project_name}-postgres"
    Project = var.project_name
  }
}

# Coder EC2 Instance (public with internet access)
resource "aws_instance" "coder" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = tolist(data.aws_subnets.default.ids)[0]
  vpc_security_group_ids = [aws_security_group.coder.id]
  key_name               = local.key_name

  # Public IP for internet access
  associate_public_ip_address = true

  # Root EBS volume configuration
  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = var.root_volume_type
    delete_on_termination = true
    encrypted             = true
    
    tags = {
      Name    = "${var.project_name}-coder-root-volume"
      Project = var.project_name
    }
  }

  # User data script to install and configure Coder
  user_data = <<-EOF
              #!/bin/bash
              set -e
              
              # Log all output to a file for debugging
              exec > >(tee -a /var/log/user-data.log)
              exec 2>&1
              
              echo "Starting Coder installation at $(date)"
              
              # Update system
              apt-get update
              apt-get upgrade -y
              
              # Install required packages and Docker for testing some templates
              apt-get install -y curl wget postgresql-client

              apt-get install -y ca-certificates curl gnupg lsb-release

              install -m 0755 -d /etc/apt/keyrings
              curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
              chmod a+r /etc/apt/keyrings/docker.gpg

              UBUNTU_CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
              echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $UBUNTU_CODENAME stable" > /etc/apt/sources.list.d/docker.list

              apt-get update -y
              apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

              systemctl enable docker
              systemctl start docker

              usermod -aG docker ubuntu || true

              # Get the instance's public IP from AWS metadata service
              echo "Fetching instance public IP..."
              PUBLIC_IP=$(curl ifconfig.me)
              echo "Instance public IP: $PUBLIC_IP"
              
              # Wait for PostgreSQL to be ready
              echo "Waiting for PostgreSQL to be ready..."
              for i in {1..30}; do
                if pg_isready -h ${aws_instance.postgres.private_ip} -p 5432 -U ${var.postgres_username}; then
                  echo "PostgreSQL is ready!"
                  break
                fi
                echo "Waiting for PostgreSQL... (attempt $i/30)"
                sleep 10
              done
              
              CODER_VERSION="${var.coder_version}"
              TAR_FILE="coder-$CODER_VERSION.tar.gz"
              INSTALL_DIR="coder-$CODER_VERSION"

              echo "Installing Coder version: $CODER_VERSION"

              # Download the tarball for the specified version
              curl -Lo "$TAR_FILE" \
                "https://github.com/coder/coder/releases/download/v$CODER_VERSION/coder_$${CODER_VERSION}_linux_amd64.tar.gz"

              # Extract into a versioned directory
              mkdir -p "$INSTALL_DIR"
              tar -xzf "$TAR_FILE" -C "$INSTALL_DIR"

              # Move the binary to /usr/bin
              chmod +x "$INSTALL_DIR/coder"
              mv "$INSTALL_DIR/coder" /usr/bin/coder


              
              # Verify Coder installation
              /usr/bin/coder version
              
              # Create coder user
              useradd -m -s /bin/bash coder || true
              
              # Create Coder data directory
              mkdir -p /var/lib/coder
              chown -R coder:coder /var/lib/coder
              
              # Create systemd service file
              cat > /etc/systemd/system/coder.service <<SYSTEMD
              [Unit]
              Description=Coder
              After=network-online.target
              Wants=network-online.target
              
              [Service]
              Type=simple
              User=coder
              Group=coder
              ExecStart=/usr/bin/coder server
              Restart=always
              RestartSec=10
              LimitNOFILE=65536
              
              # Environment variables for Coder configuration
              Environment="CODER_ACCESS_URL=http://$PUBLIC_IP:7080"
              Environment="CODER_HTTP_ADDRESS=0.0.0.0:7080"
              Environment="CODER_PG_CONNECTION_URL=postgres://${var.postgres_username}:${var.postgres_password}@${aws_instance.postgres.private_ip}:5432/${var.postgres_database}?sslmode=disable"
              
              [Install]
              WantedBy=multi-user.target
              SYSTEMD
              
              # Reload systemd, enable and start Coder service
              systemctl daemon-reload
              systemctl enable coder
              systemctl start coder
              
              # Wait for Coder to start
              sleep 10
              
              echo "Coder installation complete at $(date)!"
              echo "Access Coder at: http://$PUBLIC_IP:7080"
              EOF

  tags = {
    Name    = "${var.project_name}-coder"
    Project = var.project_name
  }

  # Explicit dependency: Postgres must be created before Coder
  depends_on = [aws_instance.postgres]
}

# ============================================================================
# Outputs
# ============================================================================

output "default_vpc_id" {
  description = "ID of the default VPC being used"
  value       = data.aws_vpc.default.id
}

output "postgres_public_ip" {
  description = "Public IP address of PostgreSQL instance"
  value       = aws_instance.postgres.public_ip
}

output "postgres_private_ip" {
  description = "Private IP address of PostgreSQL instance (used by Coder)"
  value       = aws_instance.postgres.private_ip
}

output "coder_public_ip" {
  description = "Public IP address of Coder instance"
  value       = aws_instance.coder.public_ip
}

output "coder_access_url" {
  description = "URL to access Coder"
  value       = "http://${aws_instance.coder.public_ip}:7080"
}

output "postgres_connection_string" {
  description = "PostgreSQL connection string (from Coder instance)"
  value       = "postgres://${var.postgres_username}:${var.postgres_password}@${aws_instance.postgres.private_ip}:5432/${var.postgres_database}"
  sensitive   = true
}

output "ssh_command_coder" {
  description = "SSH command to connect to Coder instance"
  value       = "ssh -i <path_to_keypair> ubuntu@${aws_instance.coder.public_ip}"
}

output "ssh_command_postgres" {
  description = "SSH command to connect to Postgres instance"
  value       = "ssh -i <path_to_keypair> ubuntu@${aws_instance.postgres.public_ip}"
}

output "security_note" {
  description = "Important security information"
  value       = "PostgreSQL port 5432 is only accessible from Coder's security group, not from the internet"
}

output "postgres_volume_id" {
  description = "Volume ID of the Postgres root EBS volume"
  value       = aws_instance.postgres.root_block_device[0].volume_id
}

output "coder_volume_id" {
  description = "Volume ID of the Coder root EBS volume"
  value       = aws_instance.coder.root_block_device[0].volume_id
}