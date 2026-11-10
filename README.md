# FortiAIGate Compose on AWS

Create a `g6e.2xlarge` server (one L40S GPU, 8 vCPUs, 64 GiB RAM), then run Fortinet’s [deployment utility](https://docs.fortinet.com/document/fortiaigate/8.0.2/fortiaigate-administration-guide/123456/deploying-fortiaigate-with-docker-compose-on-a-standalone-server) through Session Manager. No inbound ports are opened by default.

Download the official FortiAIGate Compose utility archive separately; it is not committed here. Place `FAIG_deploy-docker-compose-cli-V8.0.2-build0055-FORTINET.tar.gz` at the repository root, or set `utility_archive` to its local path.

## 1. Configure

You need Terraform 1.7+, AWS CLI credentials with infrastructure and SSM session permissions, and the [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html). Your region needs capacity for the selected instance type and sufficient On-Demand G/VT vCPU quota (at least 8 vCPUs for either 2xlarge option).

```bash
cp terraform.tfvars.example terraform.tfvars
```

For a smaller lab trial, set `instance_type = "g5.2xlarge"`. This option has 32 GiB host RAM, below the utility's 64 GiB guidance, and less GPU memory than G6e. Terraform accepting the instance type does not establish that the selected FortiAIGate models fit; verify runtime memory use after deployment. The default remains `g6e.2xlarge`.

Edit `terraform.tfvars`. Set `availability_zone = null` (or omit it) to let AWS retry across AZs offering your instance type within `aws_region`. Pin an AZ to use a standalone EC2 instance instead.

Automatic placement uses a one-instance Auto Scaling group. Terraform waits up to 20 minutes; the group can continue trying afterward, so destroy it if you cancel the deployment. Automatic rebalancing and unhealthy-instance replacement are disabled to protect application state. Switching placement modes replaces the host; back up any existing deployment first. Your AWS credentials also need Auto Scaling and launch-template permissions.

For direct browser access, optionally set `allowed_https_ip = "YOUR_PUBLIC_IPV4"` (without `/32`). Terraform opens TCP 443 only to that IP. Leave it empty for SSM-only access; clear it and apply again to remove the rule.

Choose one image source:

**Images already in ECR:** set the registry/path, without `https://` or a component name. Terraform skips repository creation and image uploads.

```hcl
existing_ecr_registry = "123456789012.dkr.ecr.us-west-2.amazonaws.com/fortiaigate"
fortiaigate_version   = "8.0.2"
fortiaigate_build     = "0055"
```

**Upload local images:** leave the registry empty and point to your ten Fortinet component archives. `terraform apply` creates the repositories and uploads them using your workstation’s AWS credentials. This requires Bash 4+, Docker, and `jq` locally.

```hcl
existing_ecr_registry = ""
image_archive_dir    = "/absolute/path/to/images"
fortiaigate_version  = "8.0.2"
fortiaigate_build    = "0055"
```

Archives must be named `FAIG_<component>-V8.0.2-build0055-FORTINET.tar` or `.tar.gz`. Preserve the build’s leading zeros. The utility archive does **not** contain application images; obtain those and your license separately from Fortinet.

Both paths require these repository suffixes and tags:

| Components | Tag |
| --- | --- |
| `api`, `webui`, `llm-gateway`, `logd`, `license_manager`, `guardrail`, `guardrail-scanner` | `V8.0.2-build0055` (match your version/build) |
| `custom-triton` | `25.11-onnx-trt-agt-rpt-s1` |
| `faig-models` | `0.0.5-s1` |
| `vllm-server` | `0.28.0-rpt-s1` |

For cross-account ECR, its repository policies must also allow the instance role to pull.

Optionally set `existing_s3_bucket = "my-deployment-artifacts"` to upload the utility archive to an existing bucket. Leave it empty to create a private bucket. Your Terraform credentials need object upload/delete access; the instance gets read access to the uploaded archive. Existing bucket policies must permit that access.

## 2. Apply and connect

```bash
terraform init
terraform apply
terraform output -raw session_command
```

Run the printed SSM command. In the session, wait for bootstrap, then switch to the deployment operator:

```bash
sudo cloud-init status --wait
sudo test -f /var/lib/fortiaigate-bootstrap-complete && echo Ready
sudo -iu faig
cd /home/faig/deploy-docker-compose
faig-ecr-login
./deploy-docker-compose.sh
```

If bootstrap failed, inspect `/var/log/fortiaigate-bootstrap.log` before proceeding.

## 3. Deploy

In the utility wizard:

- Choose **2. Docker registry** and enter the registry, version, and build printed by `faig-ecr-login`.
- Use tag pattern **`V{version}-build{build}`**.
- Keep HTTPS **443**, HTTP **8081**, and HTTP loopback binding enabled.
- Enable GPU inspection and select the single L40S.
- Use **2 GB** gateway memory, **8 GB** log budget, namespace **fortiaigate**, and no FortiCare proxy unless your environment requires one.

Choose **3. Deploy or reapply Docker Compose**, create the required recovery archive, then type **`APPLY`**. Check **4 → 1. Status and health** after startup.

## 4. Open the UI

The generated certificate is self-signed, so a browser security warning is expected. Traffic is still encrypted when using `https://`; the warning means the browser cannot verify the server’s identity.

In another local terminal:

```bash
terraform output -raw webui_tunnel_command
```

Run the printed command and open **https://localhost:8443/ui**. Accept the lab’s self-signed certificate, create the administrator and organization, and use **`https://localhost:8443`** as the organization URL. Upload your license through **Licenses**, then run on the instance:

```bash
./faig_deployment_assistant_data/deployment/compose.sh restart api
```

Keep the tunnel open while using the UI. Rerun `faig-ecr-login` before future image pulls; ECR login expires after 12 hours.

### Optional: browser-based SSM and public-IP access

If you use **EC2 console → Instances → select the instance → Connect → Session Manager → Connect**, run the instance commands from Steps 2–3 in that browser terminal. This opens a shell, but does not create a tunnel for your web browser.

To open the FortiAIGate UI without a local SSM tunnel:

1. Set `allowed_https_ip` to your public IPv4 in `terraform.tfvars` and run `terraform apply` from your Terraform workstation. Alternatively, manually add **HTTPS / TCP 443** from **My IP** (`/32`) in the instance security group’s inbound rules.
2. Copy the instance’s **Public IPv4 address** from its details and browse to **`https://<public-ip>/ui`**. Use port **443**, not the tunnel’s local port 8443. Accept the lab certificate warning.
3. During first-time organization setup, use **`https://<public-ip>`** as the external URL, without `/ui`. Upload the license and run the API restart command above from the SSM browser terminal.
4. Clear `allowed_https_ip` and apply again when finished testing, or remove a manually added rule. The public IP can change after stopping and starting the instance.

Inside the SSM terminal itself, the service is reachable at `https://localhost:443`; the public IP is for access from your own browser.

## Quick test

Set the instance’s public IP, your FortiAIGate virtual key, and a model available to that key. Run from the workstation allowed by `allowed_https_ip`.

```bash
export EC2_PUBLIC_IP=...
export MY_VIRTUAL_KEY=....

curl --http1.1 --insecure \
  https://${EC2_PUBLIC_IP}/ai/openai/v1/chat/completions \
  -H "Authorization: Bearer ${MY_VIRTUAL_KEY}" \
  -H "Content-Type: application/json" \
  --data '{
    "model": "my-provider-slug-gpt-5.6-sol",
    "messages": [{"role": "user", "content": "How many chucks can a woodchuck actually chuck?"}],
    "stream": false
  }' | jq
```

`--insecure` skips certificate verification for the lab’s self-signed certificate; HTTPS traffic remains encrypted. This example requires `curl` and `jq`.

## Cleanup

Deleting an instance manually does not stop its Auto Scaling group from requesting a replacement. If no running instance exists, connection outputs are omitted; `terraform destroy` still removes the group and remaining infrastructure.

Back up application data off-instance first: destruction or instance replacement deletes the root disk. To remove uploaded images too, set `force_destroy_artifacts = true`, run `terraform apply`, then `terraform destroy`. Existing ECR repositories and S3 buckets are never managed or deleted; the utility object uploaded by Terraform is deleted on destroy.

## Local checks

```bash
terraform fmt -check -recursive
terraform validate
terraform test
python3 -m unittest discover -s tests -p 'test_*.py'
```

Tests use mocked AWS/Docker calls and a harmless utility fixture; no Fortinet archive, AWS credentials, or live deployment is required to run them.
