# Render: envsubst '${CLUSTER_NAME} ${AUTOMODE_NODE_ROLE}' < nodeclass.yaml.tpl
# Custom NodeClass: needed because the built-in pools (and so the built-in `default` NodeClass) are disabled.
apiVersion: eks.amazonaws.com/v1
kind: NodeClass
metadata:
  name: default-automode
spec:
  role: ${AUTOMODE_NODE_ROLE}
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: ${CLUSTER_NAME}
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: ${CLUSTER_NAME}
  tags:
    Project: finops-spot-demo
    Scaler: automode
  ephemeralStorage:
    size: 20Gi
