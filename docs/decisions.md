# Quyết định thiết kế

Ngắn gọn, Karpenter là trọng tâm.

## 1. Karpenter là đối tượng chính, hai mốc so sánh còn lại
Cluster Autoscaler là cách phổ biến nhất hiện nay nên làm mốc. EKS Auto Mode là Karpenter do AWS vận hành, cho thấy cái giá của việc không tự cài. Cả ba chạy cùng workload (Online Boutique) và cùng VPC, AZ, thị trường Spot.

## 2. Một cluster, ba pool cô lập
Tạo cluster mất 12-15 phút và tốn ~$0.37/giờ nên dùng một cluster, mỗi scaler một pool (nhãn và taint `scaler=X`, nodeSelector + toleration trên Pod). Đánh đổi: chung control plane, chung CRD `nodepools.karpenter.sh`/`nodeclaims.karpenter.sh` với Auto Mode, chung quota Spot. Vì vậy có cổng go/no-go khi tổng duyệt; nếu không qua thì chuyển sang hai cluster. Chi tiết trong [runbook](runbook.md). Đây là cấu hình để demo, không phải khuyến nghị cho production.

## 3. Karpenter cấu hình
Spot trước, On-Demand dự phòng, nhiều loại máy (`c`/`m`, thế hệ > 4, 2-4 vCPU), `limits.cpu: 8`, consolidation 30 giây, `spotToSpotConsolidation` bật. Pod Identity cho IAM; hàng đợi SQS cho cảnh báo thu hồi. Không cài chart `karpenter-crd` riêng để CRD chỉ có một chủ sở hữu khi chung với Auto Mode.

## 4. Auto Mode
Chạy với pool built-in tắt và một NodePool/NodeClass tùy chỉnh. Phí Auto Mode (~12% giá On-Demand mỗi giờ instance) tính riêng, không nằm trong số OpenCost, nên mọi ô chi phí Auto Mode ghi "chưa gồm phí".

## 5. OpenCost
OpenCost cần Prometheus; dùng bản tối giản (không PVC, không node-exporter). Số tiền luôn là "ước tính theo giá list", đối chiếu với `cost-listmodel.csv`, không thay cho hóa đơn AWS.

## 6. Cách nói về kết quả
Chưa có số đo thì không kết luận "nhanh hơn" hay "rẻ hơn". n = 3 lần lặp, một region, một buổi; đây không phải benchmark thống kê. Số trong deck chỉ đến từ `results/summary.json`.

## 7. An toàn
Mọi lời gọi `kubectl`/`helm` đi qua `scripts/lib/common.sh`, dùng kubeconfig riêng `.kube/config`, từ chối cluster không phải `finops-spot-demo*`, và cần gõ xác nhận từ terminal cho `01-up.sh`/`06-down.sh`. Không có CI/CD trong repo; kiểm tra chạy local bằng `make`.
