# Kịch bản nói: Spot + Karpenter, Uptime cao, chi phí thấp

Diễn giả: Lê Kiến Troup, Platform Architect, Enops. Khán giả: sinh viên đại học. Tổng thời lượng 15:00 (chưa tính Q&A). Tốc độ nói khoảng 135 từ mỗi phút.

Quy ước dữ liệu: mọi con số đo (giây, phần trăm lỗi) hiện là chỗ trống `Đo: ___` cho đến khi chạy demo thật và điền bằng `fill_results.py`. Mọi số tiền là **ước tính** theo giá list (OpenCost và bảng giá AWS ngày 2026-10-20), không phải số đo. Khi nói trên sân khấu, chỉ đọc số có trong `demo/results/summary.json`.

Khối `<!-- notes:slide-NN -->` bên dưới được `build_deck.py` đọc làm ghi chú diễn giả của slide NN. Không sửa tên khối.

---

## Slide 01. Spot + Karpenter: Uptime cao, chi phí thấp

**Thời gian:** 0:30

**Lời thoại:**
Chào các bạn. Mình là Kiến, Platform Architect ở Enops. Hôm nay mình có 15 phút để kể một câu chuyện rất thực tế: làm sao để hệ thống chạy gần như không bao giờ sập, mà hóa đơn cloud vẫn nhẹ. Chìa khóa là hai thứ: Spot Instance và Karpenter. Mình sẽ giải thích bằng ví dụ đời thường, rồi cho các bạn xem số liệu từ một demo nhỏ.

**Cue demo:** Không có. Đứng ở slide tiêu đề, nhìn khán giả, không mở terminal.

**Dự phòng:** Nếu máy chiếu lỗi, nói thẳng nội dung ba ý chính (Spot, Karpenter, đo chi phí) và dùng bản PDF xuất từ PNG preview.

<!-- notes:slide-01 -->
Mở bài ngắn, 30 giây. Giới thiệu bản thân và chủ đề, nói rõ đây là bài cho người mới nên sẽ dùng ví dụ đời thường. Hứa trước ba phần: Spot là gì, ba cách thêm node cho EKS, và cách đo chi phí bằng OpenCost.
Nguồn: thông tin diễn giả do chính diễn giả cung cấp (Lê Kiến Troup, Platform Architect, Enops). Layout slide dùng Title Slide của Template - Remake.pptx; footer "Amazon Web Services, Inc. or its Affiliates." nằm trong layout mẫu, chưa thay (quyết định của diễn giả).
<!-- /notes:slide-01 -->

---

## Slide 02. Vì sao phải quan tâm chi phí cloud?

**Thời gian:** 1:00

**Lời thoại:**
Trong kinh nghiệm của mình, chi phí cloud thường chiếm khoảng 10 đến 20 phần trăm chi phí vận hành của một công ty công nghệ. Nghe thì nhỏ, nhưng nó là khoản tăng nhanh nhất và dễ cắt nhất mà không đụng đến lương hay sản phẩm. Câu hỏi mình muốn trả lời hôm nay là: có thể đạt gần 100 phần trăm uptime mà không đốt tiền không? Mình chia bài thành bốn phần: Spot, cách thêm node, demo đo đạc, và những cái bẫy.

**Cue demo:** Không có. Chỉ tay vào bốn thẻ chương trình ở dưới slide khi nhắc từng phần.

**Dự phòng:** Nếu bị hỏi nguồn con số 10 đến 20 phần trăm, nói đó là kinh nghiệm của diễn giả, không phải số thống kê của ngành.

<!-- notes:slide-02 -->
Con số "10-20% chi phí vận hành" là kinh nghiệm của diễn giả khi làm việc tại Enops, không phải thống kê công bố. Nếu cần nguồn công khai, thay bằng báo cáo State of FinOps của FinOps Foundation (cần kiểm tra lại số liệu trước khi dùng).
Nguồn: kinh nghiệm của diễn giả tại Enops; thay bằng báo cáo FinOps Foundation nếu có.
Câu hỏi dẫn dắt của cả bài: có thể giữ uptime gần 100% mà không đốt tiền không. Bốn thẻ agenda: Spot, 3 cách thêm node, đo bằng OpenCost, bài học.
<!-- /notes:slide-02 -->

---

## Slide 03. Spot Instance trong một bức tranh

**Thời gian:** 1:15

**Lời thoại:**
Hãy tưởng tượng một kho hàng có 100 ô. Hôm nay khách chỉ thuê 70 ô, còn 30 ô trống. Chủ kho thà bán 30 ô đó giảm giá còn hơn để trống. AWS làm y như vậy với máy chủ: phần dung lượng dư gọi là Spot. AWS nói mức giảm điển hình là 50 đến 70 phần trăm, có thể tới khoảng 90. Nhưng có một điều kiện: khi khách trả giá đầy đủ quay lại, kho sẽ gọi lại ô đó. Giống taxi còn trống chạy giá rẻ, nhưng có thể bị gọi về bất cứ lúc nào. Bạn chỉ được báo trước 2 phút.

**Cue demo:** Không có. Dừng một nhịp ở biểu tượng đồng hồ "2 phút".

**Dự phòng:** Nếu hết giờ, bỏ ví dụ taxi, giữ ví dụ kho hàng và con số 2 phút.

<!-- notes:slide-03 -->
Ẩn dụ kho hàng 100 ô: 70 ô bán đủ giá, 30 ô giảm giá nhưng có thể bị thu hồi. Spot là dung lượng EC2 dư của AWS, cảnh báo gián đoạn trước 2 phút.
Nguồn: trang AWS EC2 Spot Instances (mức giảm điển hình 50-70%, tối đa khoảng 90%) và tài liệu Spot Instance interruptions (cảnh báo 2 phút). Số "54-67% (ap-southeast-1, 2026-10-20)" lấy từ snapshot giá list trong demo/results/pricing-snapshot-ap-southeast-1.json, là giá niêm yết đọc một lần, không phải cam kết; giá Spot đổi theo AZ và theo phút.
<!-- /notes:slide-03 -->

---

## Slide 04. Workload nào hợp với Spot?

**Thời gian:** 1:00

**Lời thoại:**
Không phải thứ gì cũng nên chạy Spot. Hợp là những thứ chịu được việc bị tắt: web không giữ trạng thái, xử lý hàng đợi, batch, CI. Không hợp là cơ sở dữ liệu một bản duy nhất, hay công việc không thể làm lại. Quy tắc mình dùng là luật Murphy: cái gì có thể hỏng thì sẽ hỏng. Cho nên đừng chờ nó hỏng, hãy chủ động rút dây điện thử trước. Nếu hệ thống sống sót sau khi bạn rút dây, thì Spot không còn đáng sợ.

**Cue demo:** Không có. Hai cột Hợp và Không hợp, đọc ba ý mỗi cột.

**Dự phòng:** Nếu hết giờ, chỉ nói câu "rút dây điện thử" và chuyển slide.

<!-- notes:slide-04 -->
Hợp với Spot: ứng dụng web không giữ trạng thái, worker xử lý hàng đợi, batch, CI. Không hợp: cơ sở dữ liệu một bản, công việc dài không có checkpoint.
Luật Murphy: cái gì có thể hỏng thì sẽ hỏng; thử chủ động bằng cách rút dây điện (chính là bài demo 2 ở slide 12). Giải thích thêm khi hỏi đáp: kiểm tra bằng cách chủ động kill node chứ không chờ sự cố thật.
Nguồn: kinh nghiệm vận hành của diễn giả; hướng dẫn "Spot best practices" của AWS (linh hoạt nhiều loại instance, xử lý gián đoạn).
<!-- /notes:slide-04 -->

---

## Slide 05. Cluster hết chỗ: Pod Pending

**Thời gian:** 1:00

**Lời thoại:**
Giờ nói sang Kubernetes. Bạn sắp lớp học có 30 ghế, mà 40 sinh viên đến. 10 bạn đứng ngoài hành lang. Trong Kubernetes, 10 bạn đó là các Pod ở trạng thái Pending: chương trình đã xin chỗ nhưng chưa có máy để chạy. Câu hỏi là ai đi thêm ghế? Không phải Kubernetes tự làm. Phải có một thành phần nhìn thấy Pod Pending rồi gọi AWS cấp thêm máy. Có ba cách làm việc đó, và đó là chủ đề của slide tiếp theo.

**Cue demo:** Không có. Nếu cluster đang chạy, có thể chỉ nhanh một Pod Pending trên màn hình terminal phụ (không bắt buộc).

**Dự phòng:** Nếu thiếu giờ, gộp slide này vào lời dẫn của slide 6.

<!-- notes:slide-05 -->
Ẩn dụ lớp học hết ghế: Pod Pending là sinh viên đứng ngoài hành lang. Kubernetes scheduler chỉ xếp Pod vào node đã có; thêm node là việc của một thành phần autoscaler bên ngoài.
Nguồn: tài liệu Kubernetes về Pod lifecycle (Pending khi chưa schedule được) và tài liệu Node autoscaling của Kubernetes.
Chuyển ý: ai thêm ghế? Ba cách ở slide 6.
<!-- /notes:slide-05 -->

---

## Slide 06. 3 cách thêm node cho EKS

**Thời gian:** 1:15

**Lời thoại:**
Cách thứ nhất là Cluster Autoscaler. Nó nói chuyện với Auto Scaling Group: thấy Pod Pending thì tăng số máy của nhóm, nhóm này có loại máy cố định. Cách thứ hai là Karpenter. Nó không dùng nhóm có sẵn, mà nhìn Pod cần bao nhiêu CPU và RAM rồi gọi thẳng EC2 Fleet API chọn loại máy vừa đủ. Giống xếp ghế vừa đủ người, không thuê cả phòng. Cách thứ ba là EKS Auto Mode: về cơ chế là Karpenter nhưng do AWS vận hành cho bạn, đổi lại có thêm một khoản phí quản lý. Trong demo hôm nay, "kube net auto scaler" mình hiểu là EKS Auto Mode.

**Cue demo:** Không có. Chỉ vào ba màu: xanh dương là Cluster Autoscaler, cam là Karpenter, xanh lá là Auto Mode. Ba màu này giữ nguyên ở các slide 8, 10, 11, 12.

**Dự phòng:** Nếu người nghe không biết ASG, nói "ASG là nhóm máy có số lượng chỉnh được".

<!-- notes:slide-06 -->
Ba cách thêm node: Cluster Autoscaler (qua Auto Scaling Group và node group), Karpenter (gọi EC2 Fleet API trực tiếp, chọn instance theo Pod), EKS Auto Mode (Karpenter do AWS quản lý, tính thêm phí quản lý khoảng 12% giá On-Demand mỗi giờ instance).
Chỉ nêu sự kiện về kiến trúc, chưa so sánh nhanh chậm trước khi có số đo.
Nguồn: tài liệu Cluster Autoscaler (kubernetes/autoscaler), karpenter.sh, và tài liệu AWS "EKS Auto Mode". Phí Auto Mode: bảng giá AWS đọc ngày 2026-10-20 (ví dụ m6i.large 0.0144 USD/giờ so với On-Demand 0.12 USD/giờ), là ước tính theo giá list. "kube net auto scaler" trong đề bài được hiểu là EKS Auto Mode; cần diễn giả xác nhận.
<!-- /notes:slide-06 -->

---

## Slide 07. Karpenter hoạt động thế nào

**Thời gian:** 1:15

**Lời thoại:**
Karpenter có hai mảnh cấu hình. NodePool nói: được dùng loại máy nào, Spot hay On-Demand, tối đa bao nhiêu CPU. EC2NodeClass nói: AMI nào, subnet nào, quyền nào. Khi có Pod Pending, bốn bước: nhìn Pod cần gì, chọn máy rẻ và vừa, gọi EC2 tạo, rồi gắn Pod vào. Khi Pod đã vắng, nó gom Pod lại và tắt máy thừa sau 30 giây, gọi là consolidation. Còn khi AWS báo Spot sắp bị thu hồi, thông báo đi qua hàng đợi SQS, Karpenter dọn node đó và dựng node khác.

**Cue demo:** Không có. Đọc to hai dòng YAML: `capacity-type: spot, on-demand` và `consolidateAfter: 30s`.

**Dự phòng:** Thiếu giờ thì bỏ YAML, giữ bốn bước.

<!-- notes:slide-07 -->
Karpenter v1: NodePool (yêu cầu về instance, capacity type spot và on-demand, giới hạn CPU, consolidation) và EC2NodeClass (AMI, subnet, role). Bốn bước: quan sát Pod Pending, chọn instance, gọi EC2 Fleet, bind Pod. Consolidation tắt hoặc thay node dư; consolidateAfter 30s là giá trị chọn cho demo, không phải mặc định.
Gián đoạn Spot: sự kiện EventBridge đi vào hàng đợi SQS, Karpenter nghe và drain node.
Nguồn: tài liệu karpenter.sh (NodePools, NodeClasses, Disruption, Interruption) phiên bản 1.14.x. Đoạn YAML trên slide là rút gọn từ demo/k8s/karpenter/nodepool.yaml.tpl.
<!-- /notes:slide-07 -->

---

## Slide 08. Demo: 1 cluster, 3 autoscaler, 1 ứng dụng

**Thời gian:** 0:45

**Lời thoại:**
Đây là sơ đồ demo. Một cluster EKS, ba vùng sẵn sàng. Hai node hệ thống chạy On-Demand. Ba nhóm node riêng, mỗi nhóm do một autoscaler quản lý, có nhãn và taint riêng để Pod không chạy lẫn. Cùng một ứng dụng bán hàng Online Boutique chạy ba bản, mỗi bản trong một namespace. Vì dùng chung cluster, cùng giá Spot, cùng thời điểm, nên so sánh công bằng hơn ba cluster tách biệt. OpenCost đứng bên cạnh để đọc chi phí theo namespace.

**Cue demo:** Điểm demo 1 (chỉ đọc, an toàn): terminal 1, chạy `kubectl get nodes -L scaler` với kubeconfig của demo để thấy ba nhóm node. Chỉ chạy nếu cluster đang sống.

**Dự phòng:** Nếu cluster không sống, mở ảnh chụp màn hình `kubectl get nodes -L scaler` từ buổi tổng duyệt.

<!-- notes:slide-08 -->
Kiến trúc demo: một cluster EKS 1.35, hai node hệ thống On-Demand, ba pool node (ca, karpenter, automode) mỗi pool có nhãn và taint scaler=X, ba namespace boutique-ca, boutique-karpenter, boutique-automode, cùng OpenCost và một Prometheus nhỏ. Lý do một cluster: cùng VPC, cùng thời điểm giá Spot, tiết kiệm thời gian và tiền.
Đánh đổi (nói thật): dùng chung control plane và CRD giữa Karpenter tự cài và Auto Mode; AWS khuyên chọn một trong hai ở production, đây là cấu hình chỉ dành cho demo. Nếu cổng go/no-go khi tổng duyệt không qua, chuyển sang hai cluster và ghi chú "2 cluster" trên slide.
Nguồn: design.md mục 3.1; tài liệu AWS về chạy Karpenter cùng EKS Auto Mode. Cấu hình chưa chạy thử trên cluster thật tại thời điểm viết kịch bản.
<!-- /notes:slide-08 -->

---

## Slide 09. Đo chi phí bằng OpenCost

**Thời gian:** 1:00

**Lời thoại:**
Để biết tiền đi đâu, mình dùng OpenCost, dự án mã nguồn mở của CNCF. Luồng rất đơn giản: Prometheus thu số liệu CPU và RAM của Pod, OpenCost nhân với giá và cho ra số đô mỗi giờ theo namespace. Vì sao OpenCost mà không phải Kubecost? Một là mã nguồn mở, hai là nhẹ, ba là đủ cho bài này. Kubecost có bản thương mại với nhiều tính năng hơn. Một lưu ý quan trọng: con số này là ước tính, dựa trên giá list, không phải hóa đơn AWS. Muốn khớp hóa đơn phải dùng thêm báo cáo chi phí của AWS.

**Cue demo:** Điểm demo tùy chọn: mở giao diện OpenCost qua port-forward (đã mở sẵn từ trước giờ nói), chỉ vào chi phí theo namespace. Không bắt buộc.

**Dự phòng:** Nếu port-forward lỗi, dùng ảnh chụp giao diện OpenCost lưu từ buổi tổng duyệt.

<!-- notes:slide-09 -->
OpenCost: dự án mã nguồn mở thuộc CNCF để phân bổ chi phí Kubernetes theo namespace, label. Demo dùng Prometheus một pod nhỏ thay cho kube-prometheus-stack. Kết quả luôn gọi là "ước tính" vì dựa trên giá list và dung lượng yêu cầu, không phải hóa đơn.
Phí quản lý của Auto Mode không nằm trong số của OpenCost; báo cáo chi phí của demo cộng thêm dòng này và ghi nhãn rõ.
Nguồn: opencost.io, tài liệu OpenCost Helm chart 2.5.x (app 1.121.3). Kubecost là sản phẩm thương mại của IBM; so sánh chi tiết nằm ngoài phạm vi bài.
<!-- /notes:slide-09 -->

---

## Slide 10. So sánh: CA vs Karpenter vs Auto Mode

**Thời gian:** 1:15

**Lời thoại:**
Đây là bảng so sánh, bốn tiêu chí và ba cách. Các ô chữ mô tả cơ chế, theo tài liệu. Các ô có số đang để trống vì mình chưa đo, và mình không muốn điền số không có thật. Hàng một là chi phí, và nhớ rằng đó là ước tính. Hàng hai là thời gian scale-up từ Pending đến node sẵn sàng. Hàng ba là khả năng chịu lỗi khi Spot bị thu hồi hay node chết. Hàng bốn là độ phức tạp vận hành. Mình sẽ không kết luận cách nào tốt hơn trước khi có số.

**Cue demo:** Không có. Nếu đã có số thật từ `summary.json`, đọc đúng ô nào đã có số, ô còn trống nói "chưa đo".

**Dự phòng:** Nếu bị hỏi "vậy cái nào nhanh nhất", trả lời: chưa có số đo thì chưa kết luận.

<!-- notes:slide-10 -->
Bảng 4 tiêu chí x 3 cách. Ô định tính chỉ nêu sự kiện kiến trúc; mọi từ so sánh như nhanh hơn, rẻ hơn bị cấm trong ô và chỉ được nói sau khi có số đo của chính ô đó. Ô số hiển thị "Đo: ___" cho đến khi metric tương ứng có n lớn hơn hoặc bằng 1; ô chi phí luôn là "Ước tính (OpenCost, giá list)".
Cấu hình công bằng: Cluster Autoscaler chạy với scale-down 2 phút (mặc định 10 phút); n = 3 lần lặp, 1 region, 1 buổi; không phải benchmark thống kê. Nếu rep đầu tiên (khởi động lạnh) bị loại khỏi trung vị thì phải nói rõ.
Nguồn: tài liệu Cluster Autoscaler, karpenter.sh, AWS EKS Auto Mode (nút thay mới định kỳ, mặc định 14 ngày, tối đa 21 ngày); snapshot giá list 2026-10-20 ap-southeast-1.
<!-- /notes:slide-10 -->

---

## Slide 11. Demo 1: Scale-up bao nhiêu giây?

**Thời gian:** 1:15

**Lời thoại:**
Thí nghiệm một: tạo bốn Pod cần mỗi cái một CPU trong pool đang trống, rồi bấm giờ từ lúc Pod xuất hiện đến lúc node đầu tiên sẵn sàng. Mỗi cách chạy ba lần. Lần chạy đầu tiên là khởi động lạnh nên mình loại ra. Kết quả ở đây là số giây đo thật khi có, hiện tại các thẻ đang để trống. Điểm cần nhìn không chỉ là con số nhỏ hay lớn, mà là loại máy mỗi cách chọn và số node nó tạo.

**Cue demo:** Điểm demo 2: chỉ chạy trực tiếp khi cluster đã ấm và pool Karpenter đang ở 0 node: terminal 2, `kubectl get nodes -L scaler -w`. Mặc định dùng video quay lúc tổng duyệt.

**Dự phòng:** Phát video 60 giây đã quay, hoặc đọc bảng `RESULTS.md`. Không bao giờ đọc số chưa có trong `summary.json`.

<!-- notes:slide-11 -->
Thí nghiệm scale-up: REPLICAS=4 Pod pause, mỗi Pod 1 vCPU, 1 GiB, pool bắt đầu từ 0 node và chưa có Pod Boutique. Mốc thời gian lấy từ đối tượng API server (creationTimestamp của Pod, thời điểm Ready của node), không lấy từ đồng hồ laptop. Hiển thị trung vị của 3 lần; min-max nằm trong ghi chú sau khi có số.
Slide dùng biểu đồ cột nếu có số đo, nếu không dùng ba thẻ "TARGET: ___ s (điền sau khi đo)". Không bao giờ đưa số từ dữ liệu giả của fixture kiểm thử lên deck chính.
Nguồn: demo/results/summary.json do fill_results.py sinh từ scaleup-*.csv; thiết kế đo ở design.md mục 3.2. Tại thời điểm viết, chưa có số đo thật.
<!-- /notes:slide-11 -->

---

## Slide 12. Demo 2: Rút điện một node

**Thời gian:** 1:15

**Lời thoại:**
Thí nghiệm hai: rút dây điện thật. Khi ứng dụng đang chạy, một con probe gửi yêu cầu liên tục vào trang chủ. Mình tắt một node bằng tay, rồi đo hai thứ: mất bao nhiêu giây để có node thay thế và Pod chạy lại, và bao nhiêu phần trăm yêu cầu bị lỗi trong lúc đó. Dòng thời gian là: rút điện, node thay thế, sẵn sàng. Hiện hai thẻ số liệu của mỗi cách đang trống. Lý do ứng dụng vẫn sống nhờ nhiều bản sao, PodDisruptionBudget và rải Pod qua nhiều vùng.

**Cue demo:** Điểm demo 3: mặc định chiếu video. Chỉ chạy trực tiếp nếu còn dư thời gian và có `05-chaos-node-down.sh` đã kiểm tra; script này hỏi xác nhận trước khi tắt node.

**Dự phòng:** Phát video quay lúc tổng duyệt; nếu không có, mô tả dòng thời gian bằng lời và nói rõ chưa có số.

<!-- notes:slide-12 -->
Thí nghiệm chaos: tắt một node Spot (hoặc dùng FIS nếu bật, hoặc drain) trong khi probe gửi yêu cầu vào frontend. Đo recovery_s từ lúc kill đến khi Pod sẵn sàng trên node thay thế và tỷ lệ yêu cầu lỗi trong cửa sổ đo. Thời điểm kill lấy từ đồng hồ máy chạy script nên sai số khoảng 2 giây.
Chế độ thực tế (terminate, fis, drain) được ghi lại trong CSV và nên nói rõ khi trình bày. Các thẻ hiện là placeholder cho đến khi có hàng kind=observed.
Nguồn: demo/results/chaos-*.csv và summary.json; thiết kế ở design.md mục 7.6.
<!-- /notes:slide-12 -->

---

## Slide 13. Bài học & những cái bẫy

**Thời gian:** 1:00

**Lời thoại:**
Sáu bài học từ thực tế. Một, rải nhiều vùng sẵn sàng. Hai, cho phép nhiều loại máy, đừng khóa một loại. Ba, đặt PodDisruptionBudget. Bốn, topology spread để Pod không dồn một chỗ. Năm, luôn có phương án dự phòng On-Demand. Sáu, coi chừng cạn IP: một subnet /24 chỉ có 256 địa chỉ và AWS giữ lại 5. Mình từng gặp sự cố hơn 10 node Spot bị thu hồi cùng một lúc trong một vùng. Hệ thống sống sót vì đã rải nhiều vùng và có dự phòng.

**Cue demo:** Không có.

**Dự phòng:** Nếu thiếu giờ, nói ba điều: nhiều vùng, nhiều loại máy, có dự phòng On-Demand.

<!-- notes:slide-13 -->
Sáu mục: multi-AZ, đa dạng instance type, PDB, topology spread, fallback sang On-Demand, giám sát IP của subnet. Multi-region tốn kém hơn nhiều (trả hai hạ tầng và đồng bộ dữ liệu) nên chỉ cân nhắc khi cần.
Sự cố "10+ node mất cùng lúc" là trải nghiệm thật của diễn giả tại Enops; nguồn: kinh nghiệm của diễn giả (chưa có postmortem công khai). "/24 = 256 địa chỉ, AWS giữ 5" theo tài liệu AWS VPC "Subnet CIDR blocks".
Cắt bớt khi thiếu giờ: giữ multi-AZ, đa dạng instance và fallback.
<!-- /notes:slide-13 -->

---

## Slide 14. Mang về nhà

**Thời gian:** 1:15

**Lời thoại:**
Ba điều mang về. Một, Spot giảm chi phí đáng kể nhưng bạn phải thiết kế để chịu được bị tắt. Hai, Karpenter hoặc Auto Mode giúp chọn máy vừa đủ và thay máy nhanh, nhưng hãy đo trong hệ thống của bạn thay vì tin con số của người khác, kể cả của mình. Ba, đo chi phí bằng OpenCost trước khi tối ưu. Tài liệu để học tiếp ở dưới slide. Hãy thử Spot và Karpenter với chi phí thấp nhất, rồi nhớ xóa cluster sau khi thử. Cảm ơn các bạn, mình sẵn sàng nhận câu hỏi.

**Cue demo:** Không có. Nhắc nhanh: sau buổi nói chạy `06-down.sh` để xóa cluster demo.

**Dự phòng:** Nếu hết giờ, đọc ba ý và mời hỏi đáp ngoài giờ.

<!-- notes:slide-14 -->
Ba ý mang về: thiết kế chịu gián đoạn, đo trước khi kết luận, đo chi phí trước khi tối ưu. Tài nguyên: opencost.io, karpenter.sh, tài liệu AWS EKS Auto Mode, finops.org.
Cần diễn giả xác nhận trước khi nói: câu "sản phẩm của Enops dùng Spot cho 100% production" chỉ có trong đề bài, chưa có nguồn kiểm chứng và chưa chắc được phép công bố. Nếu chưa xác nhận thì bỏ câu này; nội dung đề bài truncated nên phần cuối của bài nói gốc chưa có.
Nhắc nhớ: xóa cluster demo bằng 06-down.sh ngay sau buổi nói; cluster rảnh tốn khoảng 0.38 USD mỗi giờ (ước tính theo giá list ngày 2026-10-20).
<!-- /notes:slide-14 -->

---

## Cắt nếu thiếu giờ

Thứ tự bỏ, từ trước ra sau:
1. Slide 9: bỏ phần so sánh với Kubecost, chỉ giữ luồng Prometheus, OpenCost, đô mỗi giờ (tiết kiệm khoảng 0:30).
2. Slide 13: chỉ đọc ba mục đầu (tiết kiệm khoảng 0:20).
3. Slide 7: bỏ đoạn YAML, giữ bốn bước (tiết kiệm khoảng 0:25).
4. Slide 5: gộp vào lời dẫn của slide 6 (tiết kiệm khoảng 0:30).

## Checklist trước giờ nói

- [ ] Cluster demo còn sống (hoặc chắc chắn dùng video): `kubectl get nodes -L scaler` chạy bằng kubeconfig của demo, không dùng kubeconfig mặc định.
- [ ] Port-forward OpenCost đã mở; ảnh chụp giao diện OpenCost dự phòng sẵn.
- [ ] Video quay lúc tổng duyệt: scale-up của ba cách, tắt node, giao diện OpenCost.
- [ ] `RESULTS.md` và `summary.json` đã được điền bằng `fill_results.py`; deck đã build lại và `verify_deck.py` chạy sạch.
- [ ] Đọc lại các hàng 2 và 3 của slide 10 so với số thật; ô chưa có số vẫn là "Đo: ___".
- [ ] Xác nhận với ban tổ chức: câu "Enops dùng Spot 100% production" và footer AWS/FCJ của template.
- [ ] Nhắc bản thân: chạy `06-down.sh` sau buổi nói (cluster tốn khoảng 0.38 USD mỗi giờ khi rảnh, ước tính).

---

## Q&A likely questions

**1. Spot có mất dữ liệu không?**
Spot lấy lại cả máy, nên dữ liệu nằm trên ổ gốc của node sẽ mất khi node bị xóa. Nên giữ dữ liệu ở dịch vụ ngoài node (RDS, S3, EBS có PersistentVolume) và để workload không giữ trạng thái chạy trên Spot.

**2. Khác gì Reserved Instances hay Savings Plans?**
Reserved và Savings Plans là cam kết dùng 1 hoặc 3 năm để giảm giá, máy không bị thu hồi. Spot không cam kết, rẻ hơn nhiều nhưng có thể bị thu hồi. Có thể kết hợp: nền ổn định dùng Savings Plans, phần co giãn dùng Spot.

**3. Vì sao không chạy hết bằng Spot?**
Vì có thành phần không chịu được gián đoạn (cơ sở dữ liệu một bản, node hệ thống, công việc không thể làm lại). Thực tế nên giữ một phần On-Demand làm nền và làm phương án dự phòng khi Spot hết.

**4. Karpenter khác Cluster Autoscaler ở đâu?**
Cluster Autoscaler tăng giảm số máy trong nhóm có loại máy định trước qua Auto Scaling Group. Karpenter chọn loại máy theo nhu cầu Pod và gọi EC2 trực tiếp, có consolidation. Chưa có số đo thì mình không kết luận cái nào nhanh hơn; hãy xem bảng slide 10.

**5. Auto Mode có đáng khoản phí 12% không?**
Phí khoảng 12% giá On-Demand mỗi giờ instance (theo bảng giá AWS ngày 2026-10-20). Đổi lại bạn không phải tự cài, vá và nâng cấp node. Đáng hay không phụ thuộc vào chi phí nhân công vận hành của bạn so với phí này; nên tính trên hệ thống thật.

**6. Nếu cả một vùng sẵn sàng bị thu hồi Spot thì sao?**
Đó là lý do phải rải nhiều vùng, cho phép nhiều loại máy, giữ dự phòng On-Demand và đặt PodDisruptionBudget. Hệ thống vẫn có thể chậm đi nhưng không nên sập hẳn.

**7. Multi-region có đắt không?**
Có, vì bạn trả hạ tầng ở hai nơi và còn chi phí đồng bộ dữ liệu giữa vùng. Chỉ nên làm khi yêu cầu sẵn sàng cao hơn khả năng của multi-AZ.

**8. OpenCost có khớp hóa đơn AWS không?**
Không chắc khớp. OpenCost cho ước tính theo giá list và mức yêu cầu tài nguyên. Muốn khớp hóa đơn cần đối chiếu với báo cáo chi phí của AWS (CUR), nằm ngoài phạm vi demo này.

**9. Cần bao nhiêu tiền để thử?**
Theo ước tính giá list, cluster rảnh khoảng 0.38 USD mỗi giờ, đỉnh khoảng 0.95 USD mỗi giờ. Một buổi tổng duyệt khoảng 5 giờ và một buổi chạy ngày nói ước tính tổng vài đô la; chưa gồm dữ liệu NAT. Nhớ xóa cluster sau khi thử.

**10. Có dùng được cho Windows hoặc GPU không?**
Có thể, nhưng demo này chỉ chạy Linux amd64 và chưa thử Windows hay GPU. Với GPU, Spot thường biến động mạnh hơn, cần kiểm tra kỹ.

**11. Chạy cơ sở dữ liệu có trạng thái trên Spot được không?**
Không khuyến khích với cơ sở dữ liệu một bản. Nếu bắt buộc, cần sao chép nhiều bản qua nhiều vùng và dữ liệu nằm ngoài node; thường nên giữ On-Demand cho phần này.

**12. Số liệu của bạn có đáng tin không?**
Đây không phải benchmark thống kê: n bằng 3 lần lặp, một region, một buổi, Cluster Autoscaler được chỉnh scale-down xuống 2 phút. Các ô chưa đo vẫn là placeholder. Hãy tự đo trong hệ thống của bạn.
