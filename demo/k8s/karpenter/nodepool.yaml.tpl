# Render: envsubst '${CLUSTER_NAME}' < nodepool.yaml.tpl   (no variable is needed today; kept for symmetry)
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: karpenter
spec:
  template:
    metadata:
      labels:
        scaler: karpenter
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default-karpenter
      taints:
        - key: scaler
          value: karpenter
          effect: NoSchedule
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: kubernetes.io/os
          operator: In
          values: ["linux"]
        # Karpenter prefers Spot and falls back to On-Demand when Spot capacity is unavailable.
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot", "on-demand"]
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["c", "m"]
        - key: karpenter.k8s.aws/instance-generation
          operator: Gt
          values: ["4"]
        - key: karpenter.k8s.aws/instance-cpu
          operator: In
          values: ["2", "4"]
      expireAfter: 168h
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 30s
    budgets:
      - nodes: "50%"
  limits:
    cpu: "8"
