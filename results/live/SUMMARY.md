# Đo thật: EKS Auto Mode vs Karpenter tự quản lý

Cluster `amazing-blues-outfit` (EKS 1.36), us-west-2, On-Demand, Karpenter 1.13.1. 3 lần chạy mỗi ô (n=3), xen kẽ thứ tự giữa hai bên.
Số liệu gốc: `runs.csv` (18 dòng), `raw/*.json`, tổng hợp: `summary.csv`. Thời gian lấy từ API server (độ phân giải 1 s), mốc 0 là thời điểm Pod đầu tiên được tạo.
Giá: ước tính theo giá list On-Demand (Pricing API, `pricing-us-west-2.json`), chưa gồm phí quản lý của Auto Mode.

Mỗi ô: trung vị (min–max).

| Replicas | Chỉ số | Auto Mode | Karpenter |
|---|---|---|---|
| 5 | Node đầu tiên Ready (s) | 16 (16–18) | 25 (24–26) |
| 5 | Tất cả Pod Ready (s) | 21 (20–23) | 27 (26–28) |
| 5 | Số node | 2 | 2 |
| 5 | Packing CPU (%) | 28.1 | 25.9 |
| 5 | Giá ước tính ($/giờ) | 0.153 | 0.153 |
| 15 | Node đầu tiên Ready (s) | 16 (15–17) | 24 (23–24) |
| 15 | Tất cả Pod Ready (s) | 28 (23–29) | 28 (27–28) |
| 15 | Số node | 2 | 2 |
| 15 | Packing CPU (%) | 84.3 | 77.7 |
| 15 | Giá ước tính ($/giờ) | 0.153 | 0.153 |
| 30 | Node đầu tiên Ready (s) | 16 (15–20) | 24 (23–25) |
| 30 | Tất cả Pod Ready (s) | 33 (32–40) | 41 (39–42) |
| 30 | Số node | 2 | 2 |
| 30 | Packing CPU (%) | 79.6 | 76.5 |
| 30 | Giá ước tính ($/giờ) | 0.306 | 0.306 |

Ghi chú: ở 30 replicas, một lần Auto Mode chọn `c6a.xlarge + c6i.xlarge` ($0.323/giờ); hai lần còn lại và cả 3 lần Karpenter chọn 2 × `c6a.xlarge` ($0.306/giờ).

Lần chạy đầu tiên (nguội, 5 replicas, `smoke.csv`): Auto Mode node Ready sau 36 s, Pod Ready sau 55 s; Karpenter 23 s và 26 s. Các lần này không nằm trong bảng trên.
Hai lần chạy thêm để quay terminal (15 replicas, đo bằng polling phía client, độ chính xác ~2 s): Auto Mode 42 s, Karpenter 29 s.

## Kết luận

- Auto Mode có node Ready sớm hơn Karpenter khoảng 8–9 s ở cả ba mức (16 s so với 24–25 s), và Pod Ready nhanh hơn ở 5 replicas (21 s so với 27 s) và 30 replicas (33 s so với 41 s); ở 15 replicas hai bên hòa (28 s).
- Karpenter không nhanh hơn Auto Mode trong thí nghiệm này. Một phần chênh lệch có thể do node tự quản lý phải chờ DaemonSet CNI (aws-node) khởi động còn Auto Mode có sẵn trong node; đây là giả thuyết, chưa kiểm chứng riêng.
- Chi phí gần như bằng nhau: cả hai đều dùng 2 node vì ràng buộc rải đều 2 AZ (topologySpread) của cả hai bên, nên thí nghiệm này không phân biệt được khả năng chọn máy vừa đủ. Chưa tính phí quản lý Auto Mode nên Auto Mode thực tế đắt hơn một chút.
- Lần chạy nguội đầu tiên của Auto Mode chậm (55 s) và một lần chạy thêm 15 replicas cũng chậm (42 s), nên độ biến thiên của Auto Mode lớn hơn con số trung vị gợi ý; n=3 là quá ít để kết luận chắc chắn.
- Giới hạn: 1 cluster, 1 region, chỉ On-Demand (không Spot nên không đo xử lý thu hồi), image `pause` nên thời gian kéo image gần như bằng 0, Pod chỉ xin 200m CPU/256Mi vì hạn mức 16 vCPU của tài khoản, và Auto Mode cùng Karpenter chạy chung một cluster.
- Độ phân giải thời gian là 1 s (timestamp của Kubernetes), nên chênh lệch dưới 2 s không có ý nghĩa.
