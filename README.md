# Coder Deployment on AWS with Terraform

This Terraform configuration deploys a complete Coder development environment on AWS with a dedicated PostgreSQL database. The setup creates two EC2 instances in your default VPC: one running Coder and another running PostgreSQL.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                    Default VPC                      │
│                                                     │
│  ┌──────────────────┐      ┌──────────────────┐   │
│  │  Coder Instance  │      │ Postgres Instance│   │
│  │  (t3.medium)     │─────▶│  (t3.medium)     │   │
│  │  Port: 7080      │      │  Port: 5432      │   │
│  │  Public IP       │      │  Public IP       │   │
│  └──────────────────┘      └──────────────────┘   │
│         │                          │               │
│         │ (HTTP/HTTPS)            │ (SSH only)    │
│         ▼                          ▼               │
└─────────────────────────────────────────────────────┘
         │
         ▼
   Internet Access
```

### Security Model
- **Coder Instance**: Accessible from the internet on ports 80, 443, 7080, and 22 (SSH)
- **PostgreSQL Instance**: Port 5432 is only accessible from the Coder security group (not from the internet)
- Both instances have public IPs but PostgreSQL is protected by security group rules
- All EBS volumes are encrypted by default

## Prerequisites

- [Terraform](https://www.terraform.io/downloads) >= 1.0
- AWS CLI configured with credentials
- An AWS account with permissions to create EC2 instances, security groups, and key pairs
- An SSH key pair (or the script will create one for you)

## Quick Start

1. **Clone the repository**
   ```bash
   git clone <repository-url>
   cd <repository-directory>
   ```

2. **Initialize Terraform**
   ```bash
   terraform init
   ```

3. **Review and customize variables** (optional)
   
   Create a `terraform.tfvars` file:
   ```hcl
   aws_region      = "us-west-2"
   project_name    = "my-coder-deployment"
   coder_version   = "2.18.5"
   instance_type   = "t3.large"
   ```

4. **Deploy the infrastructure**
   ```bash
   terraform apply
   ```

5. **Access Coder**
   
   After deployment completes, Terraform will output the Coder access URL:
   ```bash
   terraform output coder_access_url
   ```
   
   Open this URL in your browser and complete the initial Coder setup.

## Configuration Variables

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `aws_region` | AWS region to deploy resources | `us-east-1` | No |
| `instance_type` | EC2 instance type | `t3.medium` | No |
| `key_name` | Existing AWS key pair name | `""` (creates new) | No |
| `public_key_path` | Path to public key file | `~/.ssh/id_ed25519.pub` | No |
| `postgres_username` | PostgreSQL username | `coder` | No |
| `postgres_password` | PostgreSQL password | `coder` | No |
| `postgres_database` | PostgreSQL database name | `coder` | No |
| `coder_version` | Coder version to install | `latest` | No |
| `project_name` | Project name for resource tagging | `coder-simple` | No |
| `allowed_ssh_cidr` | CIDR block allowed to SSH | `0.0.0.0/0` | No |
| `root_volume_size` | Size of root EBS volume (GB) | `25` | No |
| `root_volume_type` | Type of root EBS volume | `gp3` | No |

### Security Best Practices

For production deployments, always:
- Set a strong `postgres_password`
- Restrict `allowed_ssh_cidr` to your IP or network
- Consider using AWS Secrets Manager for sensitive values
- Use a specific `coder_version` instead of `latest`

Example secure configuration:
```hcl
postgres_password = "your-secure-password-here"
allowed_ssh_cidr  = "203.0.113.0/24"  # Your office/VPN CIDR
coder_version     = "2.29.1"
```

## Outputs

After deployment, the following information is available:

```bash
# Get the Coder URL
terraform output coder_access_url

# Get SSH commands
terraform output ssh_command_coder
terraform output ssh_command_postgres

# Get IP addresses
terraform output coder_public_ip
terraform output postgres_private_ip

# Get PostgreSQL connection string (sensitive)
terraform output -raw postgres_connection_string
```

## What Gets Installed

### Coder Instance
- Ubuntu 24.04 LTS
- Coder server (specified version)
- Docker and Docker Compose
- PostgreSQL client
- Systemd service for Coder (auto-starts on boot)

### PostgreSQL Instance
- Ubuntu 24.04 LTS
- PostgreSQL 14+ (latest from Ubuntu repos)
- Configured to accept connections from Coder instance
- Database and user created automatically

## Troubleshooting

### Coder not accessible

1. Check if the service is running:
   ```bash
   ssh -i <path_to_key_pair> ubuntu@<coder_public_ip> 'sudo systemctl status coder'
   ```

2. View initialization logs:
   ```bash
   ssh -i <path_to_key_pair> ubuntu@<coder_public_ip> 'sudo cat /var/log/user-data.log'
   ```

3. Check Coder logs:
   ```bash
   ssh -i <path_to_key_pair> ubuntu@<coder_public_ip> 'sudo journalctl -u coder -n 100'
   ```

### PostgreSQL connection issues

1. Verify PostgreSQL is running:
   ```bash
   ssh -i <path_to_key_pair> ubuntu@<postgres_public_ip> 'sudo systemctl status postgresql'
   ```

2. Test connectivity from Coder instance:
   ```bash
   ssh -i <path_to_key_pair> ubuntu@<coder_public_ip> "pg_isready -h <postgres_private_ip> -p 5432"
   ```

3. Check PostgreSQL logs:
   ```bash
   ssh -i <path_to_key_pair> ubuntu@<postgres_public_ip> 'sudo tail -f /var/log/postgresql/postgresql-*-main.log'
   ```

### Instance not ready

The user-data scripts take 5-10 minutes to complete. You can monitor progress:
```bash
ssh ubuntu@<instance_ip> 'tail -f /var/log/user-data.log'
```

## Upgrading Coder

To upgrade Coder to a new version:

1. Update the `coder_version` variable
2. Run `terraform apply`
3. SSH into the Coder instance and restart the service:
   ```bash
   sudo systemctl restart coder
   ```

## Cleanup

To destroy all resources:

```bash
terraform destroy
```

**Warning:** This will permanently delete all resources including data in PostgreSQL. Make sure to backup any important data first.

## Cost Estimation

Using default settings (t3.medium instances in us-east-1):
- 2x t3.medium instances: ~$60/month
- 2x 25GB gp3 volumes: ~$4/month
- Data transfer: Variable

**Total estimated cost: ~$65-75/month**

Costs will vary based on region, instance type, and usage patterns.

## Notes

- This configuration uses the default VPC and subnet
- Both instances are assigned public IPs
- PostgreSQL is configured to listen on all interfaces but is protected by security groups
- All EBS volumes are encrypted
- Docker is installed on the Coder instance for template testing
- The setup is designed for testing/development; additional hardening is recommended for production

## Support

For issues with:
- **This Terraform configuration**: Open an issue in this repository
- **Coder itself**: Visit [Coder's documentation](https://coder.com/docs) or [GitHub](https://github.com/coder/coder)
- **AWS resources**: Consult [AWS documentation](https://docs.aws.amazon.com/)
