# Cluster Autoscaler chart 9.59.0 (appVersion 1.35.0; the CA minor must match the cluster minor).
# Render: envsubst '${CLUSTER_NAME} ${AWS_REGION}' < values.yaml.tpl
cloudProvider: aws
awsRegion: ${AWS_REGION}
autoDiscovery:
  clusterName: ${CLUSTER_NAME}
rbac:
  serviceAccount:
    create: true
    name: cluster-autoscaler # must match the Pod Identity association created by Terraform
nodeSelector:
  role: system
extraArgs:
  balance-similar-node-groups: true
  expander: least-waste
  skip-nodes-with-local-storage: false
  # Tuned on purpose (defaults are 10m); recorded as meta.ca_config="tuned".
  scale-down-unneeded-time: 2m
  scale-down-delay-after-add: 2m
resources:
  requests:
    cpu: 100m
    memory: 300Mi
