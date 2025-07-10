# Resilience Layer - Backup and Disaster Recovery
# This layer provides:
# 1. Volume backups using Velero with AWS EBS snapshots
# 2. Kubernetes API/etcd backups using Velero
# 3. S3 bucket for backup storage
# 4. Automated backup scheduling

locals {
  cluster_name = "cluster-prod"
  backup_bucket_name = "${local.cluster_name}-velero-backups-${random_string.bucket_suffix.result}"
  tags = {
    "karpenter.sh/discovery" = local.cluster_name
    "author"                 = "majid"
    "layer"                  = "resilience"
  }
}

# Random suffix for S3 bucket to ensure global uniqueness
resource "random_string" "bucket_suffix" {
  length  = 8
  special = false
  upper   = false
}

# Data sources to get existing resources
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# S3 bucket for Velero backups
resource "aws_s3_bucket" "velero_backup" {
  bucket = local.backup_bucket_name
  tags   = local.tags
}

resource "aws_s3_bucket_versioning" "velero_backup" {
  bucket = aws_s3_bucket.velero_backup.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "velero_backup" {
  bucket = aws_s3_bucket.velero_backup.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "velero_backup" {
  bucket = aws_s3_bucket.velero_backup.id

  rule {
    id     = "backup_lifecycle"
    status = "Enabled"

    # Move to IA after 30 days
    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    # Move to Glacier after 90 days
    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    # Delete after 365 days
    expiration {
      days = 365
    }

    # Clean up incomplete uploads
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_public_access_block" "velero_backup" {
  bucket = aws_s3_bucket.velero_backup.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# IAM policy for Velero
resource "aws_iam_policy" "velero_policy" {
  name        = "velero-backup-policy"
  description = "Policy for Velero backup operations"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # EBS snapshot permissions
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeVolumes",
          "ec2:DescribeSnapshots",
          "ec2:CreateTags",
          "ec2:DescribeInstances",
          "ec2:CreateSnapshot",
          "ec2:DeleteSnapshot",
          "ec2:DescribeSnapshotAttribute",
          "ec2:DescribeVolumeAttribute",
          "ec2:DescribeVolumeStatus",
          "ec2:DescribeVolumesModifications"
        ]
        Resource = "*"
      },
      # S3 permissions for backup storage
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:PutObject",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts"
        ]
        Resource = "${aws_s3_bucket.velero_backup.arn}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketVersioning",
          "s3:GetBucketLocation"
        ]
        Resource = aws_s3_bucket.velero_backup.arn
      }
    ]
  })

  tags = local.tags
}

# IRSA role for Velero
module "velero_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.32.0"

  role_name = "velero-backup"

  oidc_providers = {
    ex = {
      provider_arn               = data.aws_eks_cluster.cluster.identity[0].oidc[0].issuer
      namespace_service_accounts = ["velero:velero"]
    }
  }

  tags = local.tags
}

# Attach the policy to the role
resource "aws_iam_role_policy_attachment" "velero_policy_attachment" {
  policy_arn = aws_iam_policy.velero_policy.arn
  role       = module.velero_irsa_role.iam_role_name
}

# Data source to get the EKS cluster info
data "aws_eks_cluster" "cluster" {
  name = local.cluster_name
}

# Kubernetes namespace for Velero
resource "kubernetes_namespace_v1" "velero" {
  metadata {
    name = "velero"
    labels = {
      name = "velero"
    }
  }
}

# Service account for Velero with IRSA
resource "kubernetes_service_account_v1" "velero" {
  metadata {
    namespace = kubernetes_namespace_v1.velero.metadata[0].name
    name      = "velero"
    annotations = {
      "eks.amazonaws.com/role-arn" = module.velero_irsa_role.iam_role_arn
    }
  }
}

# Velero Helm release
resource "helm_release" "velero" {
  name             = "velero"
  namespace        = kubernetes_namespace_v1.velero.metadata[0].name
  repository       = "https://vmware-tanzu.github.io/helm-charts"
  chart            = "velero"
  version          = "5.1.0"
  timeout          = 600
  atomic           = true
  create_namespace = false

  values = [
    <<YAML
# Velero configuration
configuration:
  backupStorageLocation:
    - name: aws-s3
      provider: aws
      bucket: ${aws_s3_bucket.velero_backup.bucket}
      config:
        region: ${data.aws_region.current.name}
        s3ForcePathStyle: false
  
  volumeSnapshotLocation:
    - name: aws-ebs
      provider: aws
      config:
        region: ${data.aws_region.current.name}

# Service account configuration
serviceAccount:
  server:
    create: false
    name: velero

# Resource configuration
resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    cpu: 500m
    memory: 512Mi

# Default backup settings
initContainers:
  - name: velero-plugin-for-aws
    image: velero/velero-plugin-for-aws:v1.8.0
    imagePullPolicy: IfNotPresent
    volumeMounts:
      - mountPath: /target
        name: plugins

# Backup retention
defaultBackupTTL: 720h  # 30 days

# Metrics for monitoring
metrics:
  enabled: true
  serviceMonitor:
    enabled: false  # Enable after Prometheus is running

# Deploy node agent for file-level backups
deployNodeAgent: true

nodeAgent:
  podVolumePath: /var/lib/kubelet/pods
  privileged: false
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi
    YAML
  ]

  depends_on = [
    kubernetes_service_account_v1.velero,
    aws_s3_bucket.velero_backup
  ]
}

# Backup schedules
resource "kubernetes_manifest" "daily_backup" {
  manifest = yamldecode(<<YAML
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: daily-backup
  namespace: velero
spec:
  schedule: "0 2 * * *"  # Daily at 2 AM
  template:
    ttl: 720h  # 30 days retention
    includedNamespaces:
    - "*"
    excludedNamespaces:
    - kube-system
    - kube-public
    - kube-node-lease
    - velero
    storageLocation: aws-s3
    volumeSnapshotLocations:
    - aws-ebs
    defaultVolumesToFsBackup: false  # Use EBS snapshots by default
  YAML
  )

  depends_on = [
    helm_release.velero
  ]
}

resource "kubernetes_manifest" "weekly_full_backup" {
  manifest = yamldecode(<<YAML
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: weekly-full-backup
  namespace: velero
spec:
  schedule: "0 3 * * 0"  # Weekly on Sunday at 3 AM
  template:
    ttl: 2160h  # 90 days retention
    includedNamespaces:
    - "*"
    storageLocation: aws-s3
    volumeSnapshotLocations:
    - aws-ebs
    defaultVolumesToFsBackup: true  # File-level backup for full backup
  YAML
  )

  depends_on = [
    helm_release.velero
  ]
}

# Disaster recovery backup (monthly)
resource "kubernetes_manifest" "monthly_dr_backup" {
  manifest = yamldecode(<<YAML
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: monthly-dr-backup
  namespace: velero
spec:
  schedule: "0 4 1 * *"  # Monthly on 1st at 4 AM
  template:
    ttl: 8760h  # 365 days retention
    includedNamespaces:
    - "*"
    storageLocation: aws-s3
    volumeSnapshotLocations:
    - aws-ebs
    defaultVolumesToFsBackup: true
    includeClusterResources: true
  YAML
  )

  depends_on = [
    helm_release.velero
  ]
}

# Output important information
output "velero_backup_bucket" {
  description = "S3 bucket name for Velero backups"
  value       = aws_s3_bucket.velero_backup.bucket
}

output "velero_iam_role_arn" {
  description = "IAM role ARN for Velero service account"
  value       = module.velero_irsa_role.iam_role_arn
}

output "backup_schedules" {
  description = "Configured backup schedules"
  value = {
    daily   = "Daily at 2 AM (30 days retention)"
    weekly  = "Weekly on Sunday at 3 AM (90 days retention)"
    monthly = "Monthly on 1st at 4 AM (365 days retention)"
  }
}