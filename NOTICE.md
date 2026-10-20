# Notice

The original work in this repository is released under the [MIT License](LICENSE),
Copyright (c) 2026 Nguyễn Đức Toàn. The items below are **not** covered by that licence
or are derived from other work.

## Derived from the author's own project

- `terraform/modules/network`, `terraform/modules/eks-cluster` and the Helm chart in
  `kubernetes/boutique/` derive from the author's project `boutique-eks-argocd`
  (commit `446ed56`) and were modified for this demo. Each derived file starts with a
  `Derived from ...` header.

## Third-party software used unmodified (referenced, not vendored)

Each project keeps its own licence. They are installed from their upstream
charts/images at deploy time; no source from them is copied into this repository.

| Component | Used for | Licence |
|---|---|---|
| [Online Boutique (microservices-demo)](https://github.com/GoogleCloudPlatform/microservices-demo), by Google | Container images deployed by `kubernetes/boutique/` | Apache-2.0 |
| [Karpenter](https://github.com/aws/karpenter-provider-aws) (Helm chart `oci://public.ecr.aws/karpenter/karpenter`) | Node autoscaler under test | Apache-2.0 |
| [Cluster Autoscaler](https://github.com/kubernetes/autoscaler) chart | Baseline autoscaler | Apache-2.0 |
| [OpenCost](https://github.com/opencost/opencost-helm-chart) chart | Cost measurement | Apache-2.0 |
| [Prometheus community charts](https://github.com/prometheus-community/helm-charts) | Metrics for OpenCost | Apache-2.0 |
| [terraform-aws-modules/eks](https://github.com/terraform-aws-modules/terraform-aws-eks) (Karpenter submodule) | Karpenter IAM and SQS | Apache-2.0 |
| `registry.k8s.io/pause` (Kubernetes) | Placeholder pods in the scale-up test | Apache-2.0 |
| [`curlimages/curl`](https://github.com/curl/curl) | Availability probe | curl licence (MIT-style) |

Only the files under `kubernetes/*/values*.yaml` and the `*.tpl` manifests are this
project's own configuration for those tools.

## Not covered by the MIT licence

- `presentation/template/Template - Remake.pptx` is an AWS First Cloud Journey slide
  template. It is kept only as the base of the generated deck. Its rights stay with its
  owners; do not reuse it without their permission. The generated
  `presentation/karpenter-spot-finops.pptx` and its previews contain that template's
  layouts, artwork and footer, so they are likewise outside the MIT grant. The slide
  text and `presentation/script.md` are the author's.
- AWS, Amazon EKS, EC2, Karpenter, Kubernetes, Prometheus, OpenCost and Keyloop are
  trademarks of their respective owners. This is a personal learning project and is not
  affiliated with or endorsed by any of them.
