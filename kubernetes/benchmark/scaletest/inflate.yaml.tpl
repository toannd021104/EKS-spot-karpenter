# Scale-test workload, one per scaler. Starts at 0 replicas; 03-benchmark-scaleup.sh scales it.
# Render: envsubst '${SCALER}' < inflate.yaml.tpl      (SCALER = ca | karpenter | automode)
apiVersion: v1
kind: Namespace
metadata:
  name: scaletest-${SCALER}
  labels:
    finops.demo/scaler: ${SCALER}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: inflate
  namespace: scaletest-${SCALER}
  labels:
    app.kubernetes.io/name: inflate
    scaler: ${SCALER}
spec:
  replicas: 0
  selector:
    matchLabels:
      app.kubernetes.io/name: inflate
  template:
    metadata:
      labels:
        app.kubernetes.io/name: inflate
        scaler: ${SCALER}
    spec:
      terminationGracePeriodSeconds: 0
      nodeSelector:
        scaler: ${SCALER}
      tolerations:
        - key: scaler
          operator: Equal
          value: ${SCALER}
          effect: NoSchedule
      containers:
        - name: inflate
          image: registry.k8s.io/pause:3.10
          resources:
            requests:
              cpu: "1"
              memory: 1Gi
