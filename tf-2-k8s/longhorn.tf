# daemonset that runs on longhorn node pool in order to create Raid0 of all SSD disks
# and create mountpoint (path) which will be used by Longhorn for disk storage
resource "kubectl_manifest" "gke_raid_disks" {
  yaml_body = <<YAML
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: gke-raid-disks
  namespace: longhorn-system
  labels:
    k8s-app: gke-raid-disks
spec:
  selector:
    matchLabels:
      name: gke-raid-disks
  template:
    metadata:
      labels:
        name: gke-raid-disks
    spec:
      nodeSelector:
        cloud.google.com/gke-local-nvme-ssd: "true"
      hostPID: true
      tolerations:
      - key: "longhorn-node"
        operator: "Equal"
        value: "true"
        effect: "NoSchedule"
      containers:
      - name: startup-script
        image: gcr.io/google-containers/startup-script:v1
        securityContext:
          privileged: true
        env:
        - name: STARTUP_SCRIPT
          value: |
            set -o errexit
            set -o nounset
            set -o pipefail

            devices=()
            for ssd in /dev/disk/by-id/google-local-ssd-block*; do
              if [ -e "$${ssd}" ]; then
                devices+=("$${ssd}")
              fi
            done
            if [ "$${#devices[@]}" -eq 0 ]; then
              echo "No Local NVMe SSD disks found."
              exit 0
            fi

            seen_arrays=(/dev/md/*)
            device=$${seen_arrays[0]}
            echo "Setting RAID array with Local SSDs on device $${device}"
            if [ ! -e "$device" ]; then
              device="/dev/md/0"
              echo "y" | mdadm --create "$${device}" --level=0 --force --raid-devices=$${#devices[@]} "$${devices[@]}"
            fi

            if ! tune2fs -l "$${device}" ; then
              echo "Formatting '$${device}'"
              mkfs.ext4 -F "$${device}"
            fi

            mountpoint=/mnt/disks/raid/0
            mkdir -p "$${mountpoint}"
            echo "Mounting '$${device}' at '$${mountpoint}'"
            mount -o discard,defaults "$${device}" "$${mountpoint}"
            chmod a+w "$${mountpoint}"
YAML

}

resource "kubectl_manifest" "longhorn_iscsi" {
  yaml_body = <<YAML
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: longhorn-iscsi-installation
  namespace: longhorn-system
  labels:
    app: longhorn-iscsi-installation
  annotations:
    command: &cmd OS=$(grep -E "^ID_LIKE=" /etc/os-release | cut -d '=' -f 2); if [[ -z "$${OS}" ]]; then OS=$(grep -E "^ID=" /etc/os-release | cut -d '=' -f 2); fi; if [[ "$${OS}" == *"debian"* ]]; then sudo apt-get update -q -y && sudo apt-get install -q -y open-iscsi && sudo systemctl -q enable iscsid && sudo systemctl start iscsid && sudo modprobe iscsi_tcp; elif [[ "$${OS}" == *"suse"* ]]; then sudo zypper --gpg-auto-import-keys -q refresh && sudo zypper --gpg-auto-import-keys -q install -y open-iscsi && sudo systemctl -q enable iscsid && sudo systemctl start iscsid && sudo modprobe iscsi_tcp; else sudo yum makecache -q -y && sudo yum --setopt=tsflags=noscripts install -q -y iscsi-initiator-utils && echo "InitiatorName=$(/sbin/iscsi-iname)" > /etc/iscsi/initiatorname.iscsi && sudo systemctl -q enable iscsid && sudo systemctl start iscsid && sudo modprobe iscsi_tcp; fi && if [ $? -eq 0 ]; then echo "iscsi install successfully"; else echo "iscsi install failed error code $?"; fi
spec:
  selector:
    matchLabels:
      app: longhorn-iscsi-installation
  template:
    metadata:
      labels:
        app: longhorn-iscsi-installation
    spec:
      hostNetwork: true
      hostPID: true
      nodeSelector:
        cloud.google.com/gke-local-nvme-ssd: "true"
      tolerations:
      - key: "longhorn-node"
        operator: "Equal"
        value: "true"
        effect: "NoSchedule"
      initContainers:
      - name: iscsi-installation
        command:
          - nsenter
          - --mount=/proc/1/ns/mnt
          - --
          - bash
          - -c
          - *cmd
        image: alpine:3.17
        securityContext:
          privileged: true
      containers:
      - name: sleep
        image: registry.k8s.io/pause:3.1
  updateStrategy:
    type: RollingUpdate
YAML

  depends_on = [
    kubectl_manifest.longhorn_iscsi
  ]

}

resource "helm_release" "longhorn" {
  name             = "longhorn"
  repository       = "https://charts.longhorn.io"
  chart            = "longhorn"
  version          = "1.5.3"
  create_namespace = true
  namespace        = "longhorn-system"
  timeout          = 300
  atomic           = true
  wait             = true

  values = [
    <<EOF
persistence:
  defaultClass: false
  defaultClassReplicaCount: 3
csi:
  kubeletRootDir: /var/lib/kubelet
defaultSettings:
  deletingConfirmationFlag: true
  createDefaultDiskLabeledNodes: true
  defaultDataPath: /mnt/disks/raid/0
  kubernetesClusterAutoscalerEnabled: false
  replicaAutoBalance: best-effort
  replica-replenishment-wait-interval: 0
  storageOverProvisioningPercentage: 500
  taintToleration: "longhorn-node=true:NoSchedule"
longhornManager:
  tolerations:
    - key: "longhorn-node"
      operator: "Equal"
      value: "true"
      effect: "NoSchedule"
longhornDriver:
  tolerations:
    - key: "longhorn-node"
      operator: "Equal"
      value: "true"
      effect: "NoSchedule"

  EOF
  ]

  depends_on = [
    kubectl_manifest.gke_raid_disks,
    kubectl_manifest.longhorn_iscsi,
    kubectl_manifest.sysbox
  ]
}
