# Kiến trúc

Một cluster EKS, ba node pool cô lập. Karpenter là pool chính; Cluster Autoscaler và EKS Auto Mode chạy cùng điều kiện để so sánh.

```mermaid
flowchart LR
  subgraph AWS["AWS ap-southeast-1 (một VPC, 3 AZ, 1 NAT)"]
    subgraph EKS["EKS 1.35"]
      SYS["Node hệ thống On-Demand x2<br/>(Karpenter controller, CA, OpenCost, Prometheus)"]
      subgraph POOLS["Ba pool, mỗi pool có nhãn và taint scaler=X"]
        KP["Pool karpenter<br/>NodePool + EC2NodeClass<br/>Spot, dự phòng On-Demand"]
        CA["Pool ca<br/>Managed node group Spot<br/>Cluster Autoscaler"]
        AM["Pool automode<br/>Auto Mode NodePool"]
      end
      APPS["Namespace boutique-karpenter / boutique-ca / boutique-automode<br/>scaletest-* và finops-probe"]
    end
    SQS["SQS + EventBridge<br/>cảnh báo Spot"]
    EC2["EC2 Fleet API / ASG"]
  end
  OC["OpenCost + Prometheus nhỏ"]
  APPS -- Pod Pending --> KP
  KP -- tạo máy --> EC2
  SQS -- cảnh báo thu hồi --> KP
  CA --> EC2
  OC -. đo chi phí theo namespace .-> APPS
```

## Luồng Karpenter

1. Pod `Pending` có `nodeSelector` và toleration `scaler=karpenter`.
2. Karpenter đọc `NodePool` (Spot trước, On-Demand dự phòng, họ máy `c`/`m` thế hệ > 4, 2 hoặc 4 vCPU, giới hạn 8 vCPU) và `EC2NodeClass` (subnet và security group theo tag `karpenter.sh/discovery`).
3. Karpenter gọi EC2 Fleet API, node join cluster, Pod được xếp lên.
4. Khi Spot sắp bị thu hồi, EventBridge gửi vào SQS; Karpenter cordon, drain và thay node.
5. Consolidation (`WhenEmptyOrUnderutilized`, 30 giây) gom node thừa.

## Đo lường

`scripts/03` đo thời gian scale-up bằng workload `inflate` (pod `pause`), `scripts/05` xoá một node để đo phục hồi (probe HTTP liên tục), `scripts/04` xuất chi phí từ OpenCost cộng một mô hình giá list độc lập. `scripts/fill_results.py` gộp CSV thành `results/summary.json`; deck chỉ đọc file này.

Sơ đồ mô tả thiết kế; cluster chưa được dựng thật.
