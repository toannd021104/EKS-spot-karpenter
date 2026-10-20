# Auto Mode NodePool. Uses Auto Mode label keys (eks.amazonaws.com/*), not karpenter.k8s.aws/*.
# To verify at rehearsal: that 2-vCPU c/m sizes are accepted by Auto Mode.
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: automode
spec:
  template:
    metadata:
      labels:
        scaler: automode
    spec:
      nodeClassRef:
        group: eks.amazonaws.com
        kind: NodeClass
        name: default-automode
      taints:
        - key: scaler
          value: automode
          effect: NoSchedule
      requirements:
        - key: eks.amazonaws.com/instance-category
          operator: In
          values: ["c", "m"]
        - key: eks.amazonaws.com/instance-cpu
          operator: In
          values: ["2", "4"]
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot", "on-demand"]
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 30s
  limits:
    cpu: "8"
