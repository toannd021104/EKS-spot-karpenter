# Render: envsubst '${CLUSTER_NAME} ${KARPENTER_NODE_ROLE}' < ec2nodeclass.yaml.tpl
# Apply only after `kubectl diff` or `--dry-run=server`.
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: default-karpenter
spec:
  role: ${KARPENTER_NODE_ROLE}
  # Trade-off: al2023@latest is not pinned, so the AMI can change between rehearsal and talk.
  # The benchmark records the AMI id; pin to al2023@v<date> after the rehearsal.
  amiSelectorTerms:
    - alias: al2023@latest
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: ${CLUSTER_NAME}
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: ${CLUSTER_NAME}
  tags:
    Project: finops-spot-demo
    Scaler: karpenter
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 20Gi
        volumeType: gp3
        encrypted: true
        deleteOnTermination: true
