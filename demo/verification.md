# Verification log

Ghi lại lệnh đã chạy, kết quả, sai lệch so với design và các mục không kiểm chứng được offline.
Ngày máy: 2026-10-20. Không có lệnh nào trong file này gọi AWS, `kubectl`, `terraform apply/destroy`, `eksctl`, hay `helm install/upgrade`.

## FEAT-001: nền tảng, Terraform, Helm chart, manifest, OpenCost values

### Baseline an toàn (chạy trước khi copy bất cứ thứ gì)
- `.agents/tasks/source-sha256.txt`: sha256 của 536 file trong `/home/ubuntu/boutique-eks-argocd` (lệnh ở design §13).
- `stat -c %Y ~/.kube/config` lúc bắt đầu = `1779872505`. Phải bằng giá trị này ở bước kiểm tra cuối (FEAT-004).
- Cuối FEAT-001: `stat -c %Y ~/.kube/config` vẫn `1779872505`; `diff` sha256 nguồn sau/trước rỗng (`SOURCE_UNCHANGED`).
- Mọi file derived dùng `git -C /home/ubuntu/boutique-eks-argocd show 446ed56:<path>` (không dùng working tree bẩn).

### Công cụ deck
| Lệnh | Kết quả |
|---|---|
| `python3 -m venv deck/.venv && deck/.venv/bin/pip install -r deck/requirements.txt` | OK |
| `deck/.venv/bin/python -c 'import pptx; print(pptx.__version__)'` | `1.0.2` |
| `bash deck/render.sh /tmp/smoke-template.pptx /tmp/smoke-preview` (bản copy nguyên vẹn của `Template - Remake.pptx`) | build image `finops-deck-render`, tạo 3 PNG (`slide-01..03.png`); đã xoá file tạm trong `/tmp` |

Pin trong `deck/requirements.txt`: python-pptx 1.0.2, lxml 5.3.0, Pillow 9.0.1, PyYAML 6.0.2, XlsxWriter 3.2.0, typing_extensions 4.12.2 (hai gói cuối là phụ thuộc của python-pptx, pin để build lặp lại được).

### Terraform (`demo/terraform`, chạy không cần credentials)
| Lệnh | Kết quả |
|---|---|
| `terraform -chdir=demo/terraform fmt -check -recursive` | pass |
| `terraform -chdir=demo/terraform init -backend=false` | pass (aws 5.100.0, module `terraform-aws-modules/eks/aws//modules/karpenter` 20.37.2) |
| `terraform -chdir=demo/terraform validate` | `Success! The configuration is valid.` |
| `terraform -chdir=demo/terraform test` | `Success! 24 passed, 0 failed.` (mock provider; mỗi validation có một case bị từ chối, thêm các case chấp nhận: mặc định, `allow_open_endpoint=true`, một scaler, `enable_fis=true`) |

Sau khi chạy: đã xoá `demo/terraform/.terraform/`, giữ `.terraform.lock.hcl`. Không có `*.tfstate`, `.env`, `.git` trong `demo/`.

Output name FEAT-002 cần: `cluster_name`, `region`, `vpc_id`, `cluster_endpoint`, `enabled_scalers`, `karpenter_queue_name`, `karpenter_node_role_name`, `automode_node_role_name`, `ca_node_group_name`, `ca_asg_name`, `fis_template_ids` (map scaler -> id), `kubeconfig_command`.

### Helm chart và manifest
| Lệnh | Kết quả |
|---|---|
| `helm lint demo/k8s/boutique -f values-common.yaml -f values-<s>.yaml` cho `ca`, `karpenter`, `automode` | 0 chart failed (chỉ INFO "icon is recommended") |
| `helm template boutique-<s> demo/k8s/boutique -f ... ` cho cả 3 | pass. Mỗi release: 10 Deployment, 3 PDB (`frontend`, `productcatalogservice`, `currencyservice`), mỗi Deployment có `nodeSelector scaler=<s>` + toleration + label `scaler`; 0 match `amazonaws`/`ecr`, 0 `redis`, 0 `ExternalSecret`; ảnh `us-central1-docker.pkg.dev/online-boutique-ci/microservices-demo/<svc>:v0.10.7` |
| `helm template` không có values scaler | lỗi có chủ đích: `scheduling.scaler is required` |
| `envsubst` render mọi `.tpl` bằng giá trị giả, rồi `docker run ghcr.io/yannh/kubeconform:latest -ignore-missing-schemas -summary` trên 3 release + 3 inflate + EC2NodeClass + 2 NodePool + Auto Mode NodeClass + probe | `81 resources found in 11 files - Valid: 77, Invalid: 0, Errors: 0, Skipped: 4` (4 CRD bị bỏ qua do `-ignore-missing-schemas`). Image kubeconform digest `sha256:faffaf43f95aa6425306e1ab8d6fcad72acb9049158f38e574c085ea1ec0f64e` (tag `latest`; `lint.sh` ở FEAT-002 nên pin tag) |
| `helm template` chart thật với values của mình (đọc registry/chart công khai, không chạm cluster): `cluster-autoscaler` 9.59.0, `karpenter` 1.14.2 (OCI), `opencost` 2.5.33, `prometheus` 29.37.0 | cả 4 render được. CA có `--node-group-auto-discovery=asg:tag=...`, `scale-down-unneeded-time=2m`, `serviceAccountName: cluster-autoscaler`, `role: system`; Karpenter có `CLUSTER_NAME`, `INTERRUPTION_QUEUE`, `AWS_REGION`, `role: system`; OpenCost Service `opencost` ở ns `opencost` trỏ `prometheus-server.prometheus-system:80`; Prometheus không có DaemonSet và PVC, `role: system` ở server và kube-state-metrics, job `opencost` có mặt |

Cả 4 phiên bản pin trong design §2 vẫn tải được (xác nhận bằng `helm show values/template`, chỉ là đọc registry).

### Sai lệch so với design (đã ghi, không mở lại thiết kế)
1. **Policy block storage của Auto Mode**: design §4.3 ghi `AmazonEKSBlockStoragePolicy`; trang AWS hiện hành (`auto-cluster-iam-role.html`, đọc ngày máy 2026-10-20) liệt kê `AmazonEKSBlockStoragePolicyV2`. Dùng `V2`. Không kiểm chứng được tên policy còn tồn tại bằng AWS (không gọi AWS); nếu `terraform apply` báo không tìm thấy, đổi lại trong `modules/eks-cluster/main.tf` (`local.automode_cluster_policies`).
2. **Statement `automode-custom-tags`**: lấy nguyên văn cấu trúc từ trang `auto-cluster-iam-role.html` (7 statement), viết bằng `jsonencode` với `$${aws:PrincipalTag/...}`.
3. **Probe image**: `k8s/probe/probe.yaml.tpl` pin thẳng `curlimages/curl:8.11.1@sha256:c1fe1679c34d9784c1b0d1e5f62ac0a79fca01fb6377cdd33e90473c6f9f9a69` (digest của manifest list, tra bằng `docker buildx imagetools inspect`, đọc registry). Vì vậy file không cần biến `PROBE_IMAGE`, `envsubst` không cần danh sách biến cho file này. Quyết định 4 của impl-plan dự kiến dùng biến; kết quả tương đương nhưng đơn giản hơn.
4. **Nhãn namespace `finops.demo/scaler`** cho 3 namespace `boutique-*`: chart không tạo Namespace (Helm `--create-namespace`), nên `02-deploy-apps.sh` phải chạy `kubectl label ns` sau khi cài. Namespace `scaletest-*` và `finops-probe` đã có nhãn trong manifest.
5. **Karpenter chart values**: `karpenter/values.yaml` tĩnh; `settings.clusterName`, `settings.interruptionQueue`, `controller.env[AWS_REGION]` phải truyền bằng `--set` từ script (ghi trong comment đầu file). Thêm `settings.eksControlPlane: true` để Karpenter tự tra cluster qua `DescribeCluster`.
6. `modules/eks-cluster`: system MNG đặt `min=desired`, `max=desired+1`; `ami_type = AL2023_x86_64_STANDARD` đặt tường minh cho cả hai node group.
7. `demo/.gitignore` thêm `results/raw/*` (giữ `.gitkeep`) vì design nói raw probe logs gitignored.
8. Project root thực tế đã có `.git` (có `.gitignore`), nhưng theo chỉ dẫn không commit và không `git init`.

### Không kiểm chứng được offline (đừng coi là đã xác nhận)
- `terraform plan/apply` thật: provider chấp nhận `compute_config` với `node_pools` rỗng và không `node_role_arn`; `aws_eks_access_entry` type `EC2` cho Auto Mode; tên policy `AmazonEKSBlockStoragePolicyV2`; module Karpenter 20.37.2 tạo đúng queue/rule/Pod Identity (chỉ `validate` và `plan` với mock provider).
- Tag của MNG có lan sang ASG không (CA discovery và điều kiện IAM `aws:ResourceTag/k8s.io/cluster-autoscaler/<cluster>`).
- Auto Mode chấp nhận node 2 vCPU `c`/`m`; Karpenter + Auto Mode chung CRD (cổng coexistence).
- Tag `Project`/`Scaler` có xuất hiện trên instance Auto Mode không.
- OpenCost: tham số API `/allocation`, phân loại Spot, tắt node-exporter có làm mất widget nào không.
- Ảnh Boutique `v0.10.7` pull ẩn danh (design §0 đã kiểm bằng `docker manifest inspect`; không chạy lại).
- Mọi số đo benchmark/chi phí: chưa có, mọi ô vẫn là placeholder.

## FEAT-002: scripts, guard, results contract và test

Không có lệnh nào trong phần này gọi AWS thật, `kubectl`/`helm` vào cluster thật, `terraform apply/destroy` hay `eksctl`. Mọi test dùng stub `aws`/`kubectl`/`helm`/`terraform` trên một `PATH` chỉ gồm thư mục stub và một thư mục symlink tới tiện ích vô hại (bash, jq, sed, awk...). Thiếu stub thì test fail, không rơi xuống binary thật. Test chạy trên bản copy của `demo/scripts` trong thư mục tạm, nên không đụng `demo/.kube`, `demo/results` hay `~/.kube/config`. Account id trong test chỉ là `000000000001` và `000000000002`; ARN giả của `frt-outbound-proxy` dùng `000000000002`.

### Lệnh đã chạy và kết quả
| Lệnh | Kết quả |
|---|---|
| `bash demo/scripts/tests/test_guards.sh` | `100 passed, 0 failed` |
| `python3 demo/scripts/tests/test_confirm_pty.py` | `Ran 5 tests ... OK` (pty thật: đúng chữ thì qua, sai/rỗng thì exit 4, stdin đóng thì exit 4, biến môi trường CONFIRM/YES/FORCE/DRY_RUN không thay được gõ xác nhận) |
| `bash demo/scripts/tests/test_benchmark_preflight.sh` | `20 passed, 0 failed` |
| `bash demo/scripts/tests/test_chart.sh` | `10 passed, 0 failed` (helm lint + template cho `ca`, `karpenter`, `automode`; không ECR/Redis/ExternalSecret/Namespace; 10 Deployment, mỗi cái có nodeSelector + toleration + nhãn scaler; 3 PDB; cartservice 1 replica, không PDB; thiếu `scheduling.scaler` thì template lỗi) |
| `python3 demo/scripts/tests/test_fill_results.py` | `Ran 19 tests ... OK` |
| `bash demo/scripts/lint.sh` | `0 check(s) failed, 0 warning(s)` |
| `shellcheck -x demo/scripts/*.sh demo/scripts/lib/*.sh` (shellcheck 0.8.0 cài sẵn trên máy) | 0 finding; `lint.sh` chạy thêm Docker `koalaman/shellcheck:v0.10.0` trên 12 file (cả `tests/*.sh`), 0 finding |

`lint.sh` gồm: shellcheck (Docker, tag pin), `terraform fmt -check` + `init -backend=false` + `validate` + `test` (24 pass), `helm lint/template` ba scaler, `envsubst` mọi `.tpl` bằng đúng danh sách biến mà `02` dùng (không còn `${VAR}` sót), `yamllint` (venv), `kubeconform` (Docker `ghcr.io/yannh/kubeconform:v0.6.7`, `81 resources found in 11 files - Valid: 77, Invalid: 0, Errors: 0, Skipped: 4`), grep 12 chữ số/khoá (AC10), luật `kubectl `/`helm ` chỉ nằm trong `lib/common.sh`, và allow-list lệnh `aws` (design §19). `lint.sh` chỉ liên hệ registry Terraform/Docker để tải provider/image; không gọi AWS hay cluster, và xoá `demo/terraform/.terraform` khi thoát.

Kiểm thêm ngoài test (bỏ file tạm sau đó, không giữ lại): chạy `02` (cả 3 PHASE), `04`, `05` (3 MODE) và `06` (qua pty, 2 lần gõ xác nhận) với `DRY_RUN=1` + stub để bắt lỗi biến chưa gán/thứ tự lệnh. Phát hiện và sửa: `05` ghi dòng CSV giả khi `DRY_RUN=1` (nay không ghi gì), `06` thực thi `scale` khi dry run (nay qua `run_mut`), `02` áp dụng manifest có Namespace bằng server dry-run sẽ lỗi vì namespace chưa tồn tại (nay dùng client dry-run cho file có `kind: Namespace`).

### Bằng chứng cho các acceptance criteria
- AC9: mọi script `01`-`06` thiếu/sai `CLUSTER_NAME`, `EXPECTED_AWS_ACCOUNT_ID`, `KUBE_CONTEXT` (02-06), `PHASE` (02) thoát 2 và log của stub rỗng (không có lời gọi tool nào). `KUBE_CONTEXT` là ARN giả `arn:aws:eks:ap-southeast-2:000000000002:cluster/frt-outbound-proxy`, `boutique-dev-eks` hoặc khác `CLUSTER_NAME` đều thoát 2. `DENY_CONTEXT_REGEX` chỉ thêm pattern. `01` và `06` stdin không phải tty thoát 4, không có `terraform apply/destroy` (kể cả khi đặt `CONFIRM`, `YES`, `FORCE`, `DRY_RUN`). `require_demo_cluster`: ARN khác tài khoản/cluster, kubeconfig mode 644, thiếu tag `Project`, endpoint lệch, thiếu kubeconfig đều thoát 2; `kc` trước khi guard qua thoát 2 và không gọi kubectl; `KUBECONFIG` luôn bị ép `/dev/null`.
- AC14: `03` với pool có node, hoặc có pod khác `inflate` nhắm pool (Boutique còn), thoát 5; `REPLICAS` ngoài 1-4, `CA_MAX_SIZE` nhỏ hơn `REPLICAS`, quota Spot nhỏ hơn 3x8 vCPU thoát 2; CRD dùng chung đổi resourceVersion hoặc chưa ghi nhận thì thoát 5; trạng thái sạch qua (`PREFLIGHT_ONLY=1`) và không gọi `scale`.
- AC11: `fill_results.py` trên template rỗng cho `status=TARGET`, mọi số là `null` (chỉ 3 bộ đếm `n=0` mỗi scaler); `summary.json` đã commit khớp schema; `cost.kind` là hằng `"estimate"` trong schema và schema từ chối `observed`. Trên fixture: median scale-up `70`/`90`, `35.5` (n=2, rep 0 và dòng timeout bị loại), recovery `100` (n=2), probe `30` request/`7` lỗi/`23.33%` tính từ log thô trong cửa sổ (dòng ngoài cửa sổ và dòng rác bị bỏ), status `MEASURED`/`PARTIAL`/`TARGET`, chi phí lấy lần chạy mới nhất. Từ chối ghi dưới `demo/results` hay thư mục không thuộc `/tmp` (exit 1), `meta.synthetic` không đặt tay được, trộn run_id thật và `SYNTHETIC-` bị từ chối, header sai/ô không phải số báo `file:dòng`.
- Fixture `demo/scripts/tests/fixtures/SYNTHETIC-*` (CSV, log probe thô, `SYNTHETIC-summary.json` với `meta.synthetic=true`) là số GIẢ và khớp bản sinh lại từ `fill_results.py`; `deck/tests/` ở FEAT-003 dùng `SYNTHETIC-summary.json`.
- `demo/results/summary.json` và `RESULTS.md` được tạo bằng `python3 demo/scripts/fill_results.py` trên template rỗng; mọi ô là placeholder (`TARGET: ___ s (điền sau khi đo)`, `Đo: ___`, `Ước tính (OpenCost, giá list): $___/giờ`).
- Cuối FEAT-002: `stat -c %Y ~/.kube/config` vẫn `1779872505`; sha256 nguồn so với `source-sha256.txt` rỗng (`SOURCE_UNCHANGED`); không có `.terraform`, `*.tfstate*`, `.env`, `.git` trong `demo/`; `__pycache__` đã xoá.

### Sai lệch / quyết định (không mở lại thiết kế)
1. `shellcheck` 0.8.0 hiện có sẵn trên máy (design ghi là chưa cài). Vẫn dùng Docker `koalaman/shellcheck:v0.10.0` làm kết quả chính trong `lint.sh`; bản local cũng 0 finding.
2. `deck/requirements.txt` thêm `yamllint==1.35.1` và `pathspec==0.12.1` (yamllint chạy qua venv theo design); đã `pip install` vào `deck/.venv`.
3. `kubeconform` pin tag `v0.6.7` (FEAT-001 dùng `latest`).
4. Mỗi script có `# shellcheck source-path=SCRIPTDIR` để `shellcheck -x` chạy đúng từ mọi thư mục.
5. `06-down.sh` cũng bắt buộc `KUBE_CONTEXT` (giống 02-05) và hỏi gõ xác nhận hai lần (bước 1 và trước `terraform destroy`), theo §7.7. Cả `01` và `06` kiểm tra tty ngay sau khi validate biến, trước mọi lời gọi tool.
6. Thêm `PREFLIGHT_ONLY=1` cho `03` (chỉ kiểm tra trạng thái rồi dừng) để test preflight mà không scale; `DRY_RUN=1` của `03`/`05` không bao giờ ghi CSV.
7. Trạng thái cục bộ trong `demo/.kube/` (đã gitignore): `crd-resourceversions-<cluster>.json` (ghi sau khi cài Karpenter, `03` dùng cho cổng a) và `platform-done-<cluster>` (cho `02 PHASE=apps`); `06` xoá cả hai.
8. `04` ghi thêm dòng `source=opencost_allocation_label` (aggregate `label:scaler`); `fill_results.py` chỉ dùng dòng `opencost_allocation_namespace`, và ghép `cost-listmodel.csv` với `cost-<s>.csv` qua `run_id` để lấy `window` (tính `listmodel_per_hour_usd`). `fill_results.py` có thêm `--input-dir`, `--out`, `--prefix` (fixture), `--meta KEY=VALUE`.
9. Quota thiếu ở `01` thoát 2 (guard). `01` trừ vCPU đang chạy khỏi quota Spot/On-Demand (cluster `boutique-dev-eks` có thể cùng tài khoản/region).
10. `02`: manifest chứa Namespace dùng `--dry-run=client` trước `apply` (server dry-run lỗi vì namespace chưa có); manifest còn lại dùng `--dry-run=server`. `helm` dùng `--repo URL` thay vì `helm repo add` để không sửa cấu hình Helm của người dùng.
11. `05`: `fis` chỉ chạy được với Spot (victim On-Demand thì `mode=terminate`, ghi trong `notes`); baseline probe rỗng bị coi là không khoẻ (exit 5).

### Không kiểm chứng được offline (đừng coi là đã xác nhận)
- `01-up.sh`: luồng gõ xác nhận thật + `terraform plan/apply` thật (chỉ test được nhánh non-tty và pty của `confirm_by_typing`).
- `02`/`03`/`05`/`06` trên cluster thật: Helm repo/OCI pull, `kubectl apply` CRD Karpenter/Auto Mode, cổng coexistence, đo thời gian, kill node thật (`terminate-instances` bị từ chối trên Auto Mode?), `terraform destroy`, quét tồn dư. Mới chạy với stub và `DRY_RUN=1`.
- `04`: tham số API `/allocation` của OpenCost, phân loại Spot, giá Spot thật từ `describe-spot-price-history`.
- JMESPath của các truy vấn `aws ... --query` (tag `eks:eks-cluster-name`, `describe-instances`) chưa chạy với AWS thật.
- Vì kubectl cục bộ là 1.31.4 (< 1.34), preflight thật sẽ từ chối; test chỉ stub `kubectl version`.
- Mọi số đo benchmark/chi phí: chưa có, mọi ô là placeholder; dữ liệu duy nhất có số là fixture `SYNTHETIC-*`.
