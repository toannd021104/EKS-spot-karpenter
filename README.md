# Spot + Karpenter FinOps: bài nói 15 phút, deck và demo EKS

Gói gồm: deck 14 slide (`deck/`), kịch bản nói + speaker notes (`deck/script.md`), và demo tối thiểu EKS + Spot + Karpenter + OpenCost (`demo/`).

**Trạng thái:** demo chưa chạy thử trên cluster thật. Chỉ mới lint/test offline. Mọi số đo và chi phí là placeholder cho đến khi rehearsal.

**DESTROY:** cluster demo tốn khoảng $0.375/giờ (~$9/ngày) kể cả khi rảnh (ước tính theo giá list). Chạy xong phải chạy `demo/scripts/06-down.sh`. Chi tiết trong [demo/README.md](demo/README.md).

**An toàn:** script chỉ chạy với cluster `finops-spot-demo*`, từ chối `boutique-dev-eks` và `frt-outbound-proxy`, bắt buộc `CLUSTER_NAME` + `EXPECTED_AWS_ACCOUNT_ID`, và `01`/`06` đòi gõ xác nhận từ terminal (không bypass được). Không ghi account id vào repo. Repo nguồn `boutique-eks-argocd` chỉ đọc.

## Dựng lại deck

```bash
cd deck && python3 -m venv .venv && . .venv/bin/activate && pip install -r requirements.txt
python build_deck.py && ./render.sh && python verify_deck.py
```

`render.sh` dùng Docker (LibreOffice) để tạo `deck/preview/slide-NN.png`. Kiểm tra bằng mắt cả 14 ảnh trước khi dùng.

## Kết quả đi vào deck thế nào

`demo/scripts/03`, `04`, `05` ghi CSV thô vào `demo/results/` -> `python3 demo/scripts/fill_results.py` tạo `summary.json` + `RESULTS.md` -> `deck/build_deck.py` đọc `summary.json`. Ô chưa đo vẫn là placeholder.

## Kiểm tra

```bash
bash demo/scripts/lint.sh
deck/.venv/bin/python deck/verify_deck.py
deck/.venv/bin/python -m unittest discover deck/tests
```

## Bản đồ thư mục

| Đường dẫn | Nội dung |
|---|---|
| `Template - Remake.pptx` | template đầu vào (không sửa) |
| `deck/` | `build_deck.py`, `verify_deck.py`, `render.sh`, `script.md`, `karpenter-spot-finops.pptx`, `preview/`, `tests/` |
| `demo/terraform/` | VPC + EKS + IAM (Karpenter, CA, Auto Mode), `tests/` |
| `demo/k8s/` | chart Boutique, manifest Karpenter / Auto Mode / CA, inflate, probe |
| `demo/opencost/` | values Prometheus nhỏ + OpenCost |
| `demo/scripts/` | `01-up` ... `06-down`, `fill_results.py`, `lint.sh`, `tests/` |
| `demo/results/` | schema, template CSV, `summary.json`, `RESULTS.md`, bảng giá list |
| `demo/verification.md` | lệnh đã chạy, kết quả, sai lệch, mục chưa kiểm chứng được |
| `.agents/tasks/` | design, kế hoạch, artefact của quá trình build |
