# In-cluster availability probe: 1 request per second per scaler, one line per attempt on stdout:
#   <epoch_seconds> <http_code> <time_total>        (code 000 = timeout / connection failure)
# Epoch seconds because BusyBox date may not support %N. Runs on system nodes (survives scaler node kills).
# Image pinned by digest (curlimages/curl:8.11.1 multi-arch index, resolved 2026-10-20 with
# `docker buildx imagetools inspect`). No substitution variable is needed; the file is plain YAML.
apiVersion: v1
kind: Namespace
metadata:
  name: finops-probe
  labels:
    finops.demo/role: probe
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: probe
  namespace: finops-probe
  labels:
    app.kubernetes.io/name: probe
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: probe
  template:
    metadata:
      labels:
        app.kubernetes.io/name: probe
    spec:
      nodeSelector:
        role: system
      securityContext:
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: probe-ca
          image: curlimages/curl:8.11.1@sha256:c1fe1679c34d9784c1b0d1e5f62ac0a79fca01fb6377cdd33e90473c6f9f9a69
          command: ["/bin/sh", "-c"]
          args:
            - |
              while :; do t=$(date +%s); r=$(curl -s -o /dev/null -m 1 -w '%{http_code} %{time_total}' http://frontend.boutique-ca.svc.cluster.local:8080/ || true); echo "$t $r"; sleep 1; done
          securityContext:
            allowPrivilegeEscalation: false
          resources:
            requests: {cpu: 10m, memory: 16Mi}
            limits: {cpu: 50m, memory: 64Mi}
        - name: probe-karpenter
          image: curlimages/curl:8.11.1@sha256:c1fe1679c34d9784c1b0d1e5f62ac0a79fca01fb6377cdd33e90473c6f9f9a69
          command: ["/bin/sh", "-c"]
          args:
            - |
              while :; do t=$(date +%s); r=$(curl -s -o /dev/null -m 1 -w '%{http_code} %{time_total}' http://frontend.boutique-karpenter.svc.cluster.local:8080/ || true); echo "$t $r"; sleep 1; done
          securityContext:
            allowPrivilegeEscalation: false
          resources:
            requests: {cpu: 10m, memory: 16Mi}
            limits: {cpu: 50m, memory: 64Mi}
        - name: probe-automode
          image: curlimages/curl:8.11.1@sha256:c1fe1679c34d9784c1b0d1e5f62ac0a79fca01fb6377cdd33e90473c6f9f9a69
          command: ["/bin/sh", "-c"]
          args:
            - |
              while :; do t=$(date +%s); r=$(curl -s -o /dev/null -m 1 -w '%{http_code} %{time_total}' http://frontend.boutique-automode.svc.cluster.local:8080/ || true); echo "$t $r"; sleep 1; done
          securityContext:
            allowPrivilegeEscalation: false
          resources:
            requests: {cpu: 10m, memory: 16Mi}
            limits: {cpu: 50m, memory: 64Mi}
