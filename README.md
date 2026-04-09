# arch-k8s-rpi




pi-cluster-ops/
├── ansible/               # The playbooks we used to fix the disks/NFS
├── terraform/             # (Optional) For provisioning the OS
├── apps/
│   ├── monitoring/        # Prometheus & Grafana configs
│   ├── longhorn/          # Backup jobs and storage settings
│   └── networking/        # Flannel regex patches
└── scripts/               # Maintenance scripts
