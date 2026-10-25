# GCP Hybrid Cloud Lab

Route-based IPsec (VTI) with eBGP from an on-premises lab to Google Cloud.
Built twice in parallel, on OPNsense and on VyOS, against one Cloud Router.

All public addresses in this repository use RFC 5737 documentation ranges.
No secrets are stored here. Pre-shared keys live in Google Secret Manager.

```
 OPNsense AS65002  10.2.10.0/24 --IPsec+eBGP 169.254.10.0/30--+
                                                               +-- HA VPN --> Cloud Router AS65001 --> vpc-hub 10.8.10.0/24
 VyOS     AS65003  10.2.20.0/24 --IPsec+eBGP 169.254.20.0/30--+   (if0, if1)
```

| Path | What it is |
|---|---|
| `docs/BEGINNER_GUIDE.md` | Step-by-step build, explained in plain language |
| `terraform/` | The GCP side as code |
| `configs/vyos/vyos-edge.commands.example` | Full VyOS config with placeholders |
| `.env.example` | Non-secret lab values to copy to `~/.hybrid-lab.env` |

## Quick start (GCP side)

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # edit: no secrets go here
cp backend.hcl.example backend.hcl             # edit: your state bucket
terraform init -backend-config=backend.hcl
terraform plan -parallelism=2
```

Cost control:

```bash
terraform apply -var='enabled_tunnels=[]'                    # USD 0.00/hr
terraform apply -var='enabled_tunnels=["opnsense","vyos"]'   # ~USD 0.10/hr
```

## Security

- PSKs: Secret Manager only. Generate with `openssl rand -hex 24`.
- State: GCS bucket with versioning, uniform access and public access prevention. State contains secret values.
- CI: plan only, keyless auth (Workload Identity Federation), actions pinned to commit SHAs, `permissions: {}` by default.
- Commits: gitleaks plus a local denylist hook (`scripts/check-sanitized.sh`).

## License

MIT
