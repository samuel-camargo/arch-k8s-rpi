# arch-k8s-rpi


.
├── ansible
│   ├── bootstrap_cluster.yml
│   └── hosts.ini
├── apps
│   ├── longhorn/               <-- Payload folder
│   │   └── install.yaml
│   ├── longhorn-app.yaml       <-- Wrapper
│   ├── monitoring/             <-- Payload folder
│   │   └── prometheus-raw-backup.yaml
│   ├── monitoring-app.yaml     <-- Wrapper
│   ├── networking/             <-- Payload folder
│   │   └── cluster-config.yaml
│   ├── networking-app.yaml     <-- Wrapper
│   └── root-app.yaml           <-- The Boss
└── build_arch_img_rpi.sh

pi-cluster-ops/
├── ansible/               # The playbooks we used to fix the disks/NFS
├── terraform/             # (Optional) For provisioning the OS
├── apps/
│   ├── monitoring/        # Prometheus & Grafana configs
│   ├── longhorn/          # Backup jobs and storage settings
│   └── networking/        # Flannel regex patches
└── scripts/               # Maintenance scripts
