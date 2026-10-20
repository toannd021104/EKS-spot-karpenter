# Security

## Reporting an issue

Open a [GitHub issue](https://github.com/toannd021104/EKS-spot-karpenter/issues) for
anything that is not sensitive. If you found a leaked credential or a vulnerability in
the scripts, use GitHub's private "Report a vulnerability" option on the repository's
Security tab instead of a public issue. This is a personal project, so replies are best effort.

## Ground rules

- Never commit credentials: AWS keys, `*.tfstate`, `terraform.tfvars`, kubeconfigs, `.env`
  or `*.pem` files. They are git-ignored; keep it that way.
- AWS account ids are passed through environment variables at run time
  (`EXPECTED_AWS_ACCOUNT_ID`). Only the synthetic ids `000000000001` and
  `000000000002` may appear in the repository. `scripts/lint.sh` checks this.
- The demo creates **billable AWS resources** (EKS, NAT gateway, EC2). Run it only in an
  account you own, set a budget alert, and finish with `scripts/06-down.sh`.
  See [docs/runbook.md](docs/runbook.md).
