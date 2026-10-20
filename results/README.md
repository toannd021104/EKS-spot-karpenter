# demo/results

Thư mục chứa kết quả đo của buổi demo. Các file đang commit chỉ là **placeholder**: chưa có số đo thật nào ở đây.

## Các file

- `templates/*.csv`: chỉ có dòng header (`scaleup.csv`, `chaos.csv`, `cost.csv`, `cost-listmodel.csv`). Các script 03/04/05 dùng header này để tạo `scaleup-<scaler>.csv`, `chaos-<scaler>.csv`, `cost-<scaler>.csv`, `cost-listmodel.csv` ngay trong thư mục này khi chạy thật.
- `raw/`: probe log thô của bước chaos. `logs/`: log của từng lần chạy. Cả hai để trống khi chưa đo.
- `schema/summary.schema.json`: schema của `summary.json`.
- `pricing-snapshot-ap-southeast-1.json`: bảng giá list viết tay (không sinh tự động), dùng cho ước tính chi phí.
- `summary.json`, `RESULTS.md`: tự sinh bởi `fill_results.py`, không sửa tay. Hiện sinh từ template rỗng nên mọi ô là `TARGET` / `Đo: ___`.

## kind=observed và kind=estimate

- `observed`: số đo trực tiếp (thời gian provision, thời gian pod chạy hết, phục hồi khi mất node, request lỗi trong cửa sổ).
- `estimate`: ước tính chi phí từ OpenCost theo giá list. Không phải hóa đơn thật và không được trình bày như số đo.

## Dữ liệu giả (synthetic)

`fill_results.py` coi run_id bắt đầu bằng `SYNTHETIC-` là dữ liệu giả. Dữ liệu này chỉ được ghi dưới `/tmp`, tuyệt đối không ghi vào `demo/results`. `build_deck.py` cũng từ chối build deck từ dữ liệu giả.

## Luồng làm việc

1. Chạy `03-benchmark-scaleup.sh`, `04-cost-report.sh`, `05-chaos-node-down.sh` (trong `demo/scripts/`) để ghi CSV vào thư mục này.
2. `python3 demo/scripts/fill_results.py` để sinh `summary.json` và `RESULTS.md`.
3. `deck/.venv/bin/python deck/build_deck.py` để đưa số vào deck, sau đó `bash deck/render.sh` và `deck/.venv/bin/python deck/verify_deck.py`.
4. Đọc lại slide 10-12 trước khi trình bày.
