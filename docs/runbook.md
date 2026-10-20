# Runbook: Karpenter vs Cluster Autoscaler vs EKS Auto Mode trên Spot (EKS, OpenCost)

> **Trạng thái: chưa chạy thử trên cluster thật.** Mọi thứ trong repo này mới chỉ được lint và test offline (terraform validate/test, helm lint/template, kubeconform, shellcheck, test với stub). Chưa có số đo nào. Mọi ô benchmark/chi phí là placeholder (`Đo: ___`, `Ước tính (...): $___/giờ`, `TARGET: ___ s (điền sau khi đo)`) cho đến khi bạn chạy buổi rehearsal.

```
+--------------------------------------------------------------------------+
|  DESTROY: CLUSTER NÀY TỐN TIỀN KHI ĐANG CHẠY, KỂ CẢ KHI KHÔNG LÀM GÌ.      |
|  Chạy xong PHẢI chạy 06-down.sh. Không để qua đêm.                        |
|                                                                          |
|  Rảnh (EKS + NAT + EIP + 2 x t3.large) : ~ $0.375/giờ  (~ $9/ngày)       |
|  Chạy 3 release Boutique               : ~ $0.70/giờ                      |
|  Đỉnh khi scale test                   : ~ $0.95/giờ  (~ $23/ngày)        |
|  Quên 1 tháng                          : ~ $270 (rảnh) đến ~ $510 (steady)|
|  Tất cả là "ước tính theo giá list" (2026-10-20), chưa phải hóa đơn.      |
|                                                                          |
|  Destroy:  CLUSTER_NAME=... EXPECTED_AWS_ACCOUNT_ID=... KUBE_CONTEXT=... \ |
|            bash scripts/06-down.sh                                  |
+--------------------------------------------------------------------------+
```

Khuyến nghị đặt AWS Budget cảnh báo khoảng $10 (project này không tạo budget).

## Quy tắc an toàn

- Các script chỉ chạy với cluster `finops-spot-demo*` (regex `^finops-spot-demo(-[a-z0-9-]{1,20})?$`). Cluster `boutique-dev-eks` và `frt-outbound-proxy` bị từ chối theo tên (`DENY_CONTEXT_REGEX`, chỉ có thể THÊM pattern).
- Bắt buộc đặt `CLUSTER_NAME` và `EXPECTED_AWS_ACCOUNT_ID` rõ ràng; script 02-06 còn cần `KUBE_CONTEXT` trùng `CLUSTER_NAME`. Thiếu hoặc sai thì thoát mã 2 và chưa gọi công cụ nào.
- Script chỉ dùng kubeconfig riêng `.kube/config` (`KUBECONFIG=/dev/null` cho mọi lời gọi khác). Không bao giờ sửa `~/.kube/config`.
- `01-up.sh` và `06-down.sh` bắt gõ xác nhận từ `/dev/tty`. Không có biến môi trường hay cờ nào bỏ qua được; không có terminal thì thoát mã 4. Người thật phải gõ.
- Mọi script in cảnh báo chi phí trước khi làm việc. `DRY_RUN=1` chỉ in việc sẽ làm.
- Account id không bao giờ được ghi vào repo; truyền bằng biến môi trường lúc chạy.
- Việc tạo/xóa tài nguyên AWS thật chỉ xảy ra khi bạn tự chạy `01-up.sh` / `06-down.sh` (và các thay đổi có tài liệu của `05`). Gói này chưa tạo gì trên AWS.

## Yêu cầu

| Công cụ | Phiên bản |
|---|---|
| terraform | >= 1.9 (đã thử 1.13.4) |
| kubectl | **>= 1.34** (cluster EKS 1.35, lệch tối đa 1 minor). Máy hiện có 1.31.4 sẽ bị preflight từ chối; cần cài bản mới hơn trước khi rehearsal |
| helm | 3.x |
| aws CLI | v2, đã đăng nhập đúng tài khoản demo |
| jq, envsubst, python3 | có sẵn |
| Docker | chỉ để lint/render (shellcheck, kubeconform, LibreOffice) |

Biến môi trường:

| Biến | Ý nghĩa |
|---|---|
| `CLUSTER_NAME` | ví dụ `finops-spot-demo` |
| `EXPECTED_AWS_ACCOUNT_ID` | 12 chữ số của tài khoản demo; script so với `sts get-caller-identity` |
| `KUBE_CONTEXT` | bằng `CLUSTER_NAME` (cho 02-06) |
| `AWS_REGION` | mặc định `ap-southeast-1` |

Chuẩn bị: `cp terraform/terraform.tfvars.example terraform/terraform.tfvars`, điền `endpoint_public_access_cidrs` bằng IP `/32` của bạn và `owner`. Giá trị mẫu `000000000000` là giả.

## Quyết định: MỘT cluster, ba node pool cô lập

Dùng một cluster với ba pool (`ca`, `karpenter`, `automode`), bật/tắt bằng `enabled_scalers`.

Lý do: tạo cluster mất khoảng 12-15 phút nên một cluster vừa với "tạo trước giờ nói"; thêm một cluster tốn khoảng +$0.37/giờ (+$9/ngày); cùng VPC, AZ, thị trường Spot, OpenCost và Prometheus nên so sánh công bằng hơn.

Đánh đổi (nói thẳng): chung control plane, chung CRD (`nodepools.karpenter.sh`, `nodeclaims.karpenter.sh`) giữa Karpenter tự quản và Auto Mode, chung quota Spot (32 vCPU), pod lạc pool có thể gây nhiễu. Vì vậy cô lập phải được cưỡng chế: nhãn + taint `scaler=X` trên node, nodeSelector + toleration + nhãn trên pod, pod hệ thống chỉ chạy trên node `role=system`, pool built-in của Auto Mode tắt. Cấu hình này chỉ để demo, không phải khuyến nghị cho production.

### Cổng go/no-go (rehearsal đầu tiên)

Chỉ giữ bố cục một cluster nếu cả ba điều sau đạt:

- (a) sau khi cài Karpenter, `resourceVersion` của hai CRD dùng chung không đổi (một chủ sở hữu);
- (b) NodePool Auto Mode và NodePool Karpenter đều `Ready=True`, NodeClass Auto Mode `Ready`;
- (c) với mỗi scaler, pod `inflate` Pending chỉ tạo node trong pool của nó (số node tạo ở hai pool còn lại bằng 0).

(a) và (b) được `02-deploy-apps.sh PHASE=platform` kiểm tự động; (c) là assertion trong từng rep của `03`. Sai một điều là script thoát mã 5 và in phương án dự phòng.

### Phương án dự phòng: hai cluster

Chạy Auto Mode ở cluster thứ hai: cluster 1 dùng `enabled_scalers=["ca","karpenter"]`, cluster 2 dùng `cluster_name=finops-spot-demo-am` và `enabled_scalers=["automode"]` (workspace Terraform riêng). Tốn thêm khoảng +$0.37/giờ (+$9/ngày) và +15 phút tạo cluster. Các script nhận `CLUSTER_NAME` nên chạy lại cho từng cluster; footnote của deck ghi "2 cluster". Kết quả cổng và bố cục ghi vào `summary.json` `meta.layout` (`one-cluster` hoặc `two-cluster`).

## "kube net auto scaler" = EKS Auto Mode

Gói này hiểu cụm "kube net auto scaler của AWS" trong đề bài là **EKS Auto Mode** (Karpenter do AWS quản lý). Nếu bạn muốn nói thứ khác (Cluster Autoscaler, Karpenter, KEDA) hãy báo để sửa. Diễn giả cần xác nhận cách hiểu này. Auto Mode chạy với pool built-in tắt và một NodePool/NodeClass tùy chỉnh; đây là cách dùng khác đường mặc định của tài liệu AWS, và phí Auto Mode (~12% giá On-Demand mỗi instance-giờ) được tính riêng, không nằm trong số OpenCost.

## OpenCost + Prometheus nhỏ

OpenCost cần Prometheus; dùng bản tối giản (1 pod server + kube-state-metrics, không node-exporter, không PVC). Đánh đổi: dữ liệu mất khi pod restart, vài widget có thể trống, giá Spot thật không có feed nên OpenCost có thể dùng giá list. Vì thế mọi số tiền trong deck là "ước tính theo giá list", đối chiếu thêm với mô hình giá độc lập (`cost-listmodel.csv`), và không thay cho hóa đơn AWS.

## Runbook

### Phiên rehearsal (ít nhất 1 ngày trước buổi nói)

Đặt biến trước:

```bash
export CLUSTER_NAME=finops-spot-demo
export EXPECTED_AWS_ACCOUNT_ID=<12 chữ số tài khoản demo>
export AWS_REGION=ap-southeast-1
```

| Mốc | Việc | Ước tính |
|---|---|---|
| R-24h | Kiểm quota Spot/On-Demand, `terraform plan` thử | 15 phút |
| R+0:00 | `bash scripts/01-up.sh` (gõ xác nhận) | ~15 phút |
| R+0:20 | đặt `KUBE_CONTEXT` (lệnh có trong output `kubeconfig_command` của Terraform), `PHASE=platform bash scripts/02-deploy-apps.sh`, cổng coexistence | ~15 phút |
| R+0:35 | `bash scripts/03-benchmark-scaleup.sh` trên pool rỗng | 45-60 phút |
| R+1:35 | `PHASE=apps bash scripts/02-deploy-apps.sh` | ~10 phút |
| R+1:45 | chờ cửa sổ chi phí 60 phút, quay màn hình OpenCost UI | 60 phút |
| R+2:45 | `bash scripts/04-cost-report.sh`, rồi `bash scripts/05-chaos-node-down.sh` | 30-45 phút |
| sau đó | quay video/chụp màn hình dự phòng; `python3 scripts/fill_results.py`; dựng lại deck | 30 phút |
| cuối | `bash scripts/06-down.sh` (gõ xác nhận hai lần) | ~15 phút |

Tổng khoảng 5 giờ, ước tính $3.5-4.5. Thứ tự quan trọng: `03` phải chạy TRƯỚC khi có pod Boutique (pod Boutique giữ node sống nên pool không còn rỗng). Chạy lại `03` sau khi đã deploy app thì phải `PHASE=apps-down` trước.

### Phiên ngày nói (tùy chọn)

T-120 phút `01-up.sh`; T-100 `02 PHASE=platform`; T-85 `02 PHASE=apps`; T-0 buổi nói; ngay sau đó `06-down.sh`. Ước tính ~2.5 giờ, ~$1.5-2. Tổng hai phiên khoảng $5-7.

## Đưa kết quả vào deck

```bash
python3 scripts/fill_results.py          # CSV thô -> results/summary.json + RESULTS.md
cd presentation && . .venv/bin/activate
python build_deck.py && ./render.sh && python verify_deck.py
```

Ô nào chưa có số đo (n = 0) vẫn là placeholder. Số trong deck chỉ đến từ `summary.json`. Số chi phí luôn mang nhãn "ước tính".

## Kế hoạch quay dự phòng

Quay trước (đừng chỉ dựa vào live): scale-up của từng scaler (`kubectl get nodes -L scaler` song song `kubectl get pods`), cảnh kill node và pod phục hồi (`05`), OpenCost UI với bảng allocation theo `scaler`. Cũng chụp bảng kết quả. Mặc định deck dùng kết quả đã đo + một lệnh `kubectl get nodes -L scaler` live ở slide 8; live scale-up chỉ khi cluster đang ấm và mạng ổn.

## Xử lý sự cố

- **Quota/ICE**: `01` thoát mã 2 nếu quota thiếu (đã trừ vCPU đang chạy). Spot hết capacity (ICE): Karpenter sẽ fallback On-Demand, CA thì pending; chạy lại sau vài phút hoặc đổi AZ/instance type.
- **Pod Pending mãi**: kiểm tra pod có `nodeSelector` + toleration `scaler=X` chưa; xem `limits.cpu: 8` của pool; xem log controller của scaler tương ứng.
- **CA không scale**: kiểm tra tag ASG `k8s.io/cluster-autoscaler/enabled` và `k8s.io/cluster-autoscaler/<cluster>=owned` (tag của managed node group có lan sang ASG không là mục chưa kiểm chứng).
- **Cổng coexistence fail (mã 5)**: dùng phương án hai cluster ở trên.
- **`05` bị từ chối terminate trên Auto Mode**: dùng `MODE=drain` hoặc `MODE=fis`, ghi vào kết quả.
- **kubectl quá cũ**: preflight từ chối kubectl < 1.34.
- **Còn tài nguyên sau destroy**: `06` thoát mã 5 và in danh sách tồn dư; không chạy `terraform destroy` mù.

## Kiểm tra offline

```bash
bash scripts/lint.sh          # shellcheck, terraform fmt/validate/test, helm, kubeconform, yamllint, grep bí mật
bash scripts/tests/test_guards.sh
python3 scripts/tests/test_confirm_pty.py
bash scripts/tests/test_benchmark_preflight.sh
bash scripts/tests/test_chart.sh
python3 scripts/tests/test_fill_results.py
terraform -chdir=terraform test
```

Danh sách việc chưa kiểm chứng được offline nằm trong `docs/verification.md`.
