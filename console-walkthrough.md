# FortiAIGate deployment through the AWS console

This walkthrough follows the repository's EC2 configuration and uses the FAIG utility's **release archive folder** option to load images directly on the instance. It targets **FAIG 8.0.2 build0055**.

Use an existing VPC and public subnet, browser-based SSM for the terminal, and HTTPS from your own IP for the WebUI. Upload the FAIG utility and component archives from your laptop through the S3 console, then download them onto the instance. The utility imports the archives locally.

## 1. Start in the EC2 console and launch the instance

Open the **EC2 console** and select **US West (Oregon), `us-west-2`**, matching the Terraform default.

This walkthrough assumes:

- An existing VPC with DNS resolution enabled and a public subnet whose route table has **`0.0.0.0/0` → an internet gateway**. Existing network ACLs must permit the required traffic and responses.
- At least **8 vCPUs** available under the EC2 quota **Running On-Demand G and VT instances**.
- Your signed-in identity can launch EC2 instances, create/pass an IAM role, start SSM sessions, and create/upload to an S3 bucket.
- The FAIG utility archive, all ten component image archives, and your license are available on your laptop.

Use **`g6e.2xlarge`**: the repository's default, with 8 vCPUs, 64 GiB RAM, and one NVIDIA L40S GPU.

Open **EC2 → Instances → Launch instances**, then configure:

| Setting | Value |
| --- | --- |
| Name | `fortiaigate-lab` |
| AMI | **Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04)** |
| Architecture | **64-bit x86** |
| Instance type | **`g6e.2xlarge`** |
| Key pair | **Proceed without a key pair** |
| VPC | Your existing VPC |
| Subnet | An existing public subnet in an AZ offering `g6e.2xlarge` |
| Auto-assign public IP | **Enable** |
| Root volume | **300 GiB**, **gp3**, **encrypted** |
| Number of instances | **1**, using On-Demand capacity |

Under AMI selection, choose **Browse more AMIs** and search for the full AMI name. Select an **Amazon-owned** image. This is the AMI family resolved by the Terraform; its release includes the NVIDIA driver, container toolkit, and SSM Agent. AMI IDs vary by region and release. [AWS AMI documentation](https://docs.aws.amazon.com/dlami/latest/devguide/aws-deep-learning-x86-base-gpu-ami-ubuntu-22-04.html)

Under **Network settings**, create a security group named **`fortiaigate-lab`**:

- **Inbound:** HTTPS, TCP **443**, source **My IP** (`your-public-ip/32`).
- **Outbound:** allow all traffic.
- Remove any automatically added SSH rule.

Before completing **Advanced details**, create the instance role if you do not already have a suitable one. Open **IAM** in another browser tab:

1. Go to **Roles → Create role**.
2. Select **AWS service** as the trusted entity and **EC2** as the use case.
3. Attach these two **AWS managed policies**:
   - **`AmazonSSMManagedInstanceCore`** — lets the instance register with Systems Manager and support SSM sessions.
   - **`AmazonS3ReadOnlyAccess`** — lets the instance list and download the staged archives.
4. Name the role **`fortiaigate-ec2-ssm`** and create it.
5. Return to the EC2 launch tab and refresh the IAM instance profile list.

`AmazonS3ReadOnlyAccess` grants S3 read access across resources, subject to other applicable controls; it is not restricted to the staging bucket. This walkthrough uses AWS managed policies rather than a custom bucket-specific policy. [AWS S3 policy reference](https://docs.aws.amazon.com/aws-managed-policy/latest/reference/AmazonS3ReadOnlyAccess.html)

Under **Advanced details**:

- **IAM instance profile:** `fortiaigate-ec2-ssm`
- **Metadata accessible:** enabled
- **Metadata version:** V2 only / tokens required
- **Metadata response hop limit:** `1`
- **User data:** leave empty

Launch the instance and wait for its status checks to pass. These fields are available through the [EC2 launch wizard](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-launch-instance-wizard.html).

If AWS reports insufficient capacity, try a subnet in another Availability Zone offering this instance type.

## 2. Upload the archives through the S3 console

While the instance starts, open the **S3 console** in another browser tab. Use a bucket in the **same AWS account and Region** as the instance.

1. Choose **Create bucket**.
2. Select a **General purpose** bucket in **`us-west-2`**.
3. Enter a globally unique name, such as **`fortiaigate-artifacts-YOUR-UNIQUE-SUFFIX`**. Record the actual name for the download commands below.
4. Keep **Object Ownership: Bucket owner enforced (ACLs disabled)**.
5. Keep **Block all public access** enabled.
6. Keep bucket versioning disabled for this temporary staging bucket.
7. Use **server-side encryption with Amazon S3 managed keys (SSE-S3)**. This avoids needing additional KMS permissions for the instance.
8. Create the bucket.

In the bucket's **Objects** tab:

1. Choose **Create folder** and name it **`cli`**.
2. Open **`cli/`**, choose **Upload → Add files**, and select **`FAIG_deploy-docker-compose-cli-V8.0.2-build0055-FORTINET.tar.gz`** from your laptop.
3. Choose **Upload** and wait for success.
4. Return to the bucket root and create a folder named **`images`**.
5. Open **`images/`**, choose **Upload → Add files**, and select all ten FAIG component image archives from your laptop.
6. Choose **Upload** and wait until every file succeeds. Keep the upload page open while the transfers run.

The resulting layout should be:

```text
s3://YOUR-BUCKET-NAME/
  cli/
    FAIG_deploy-docker-compose-cli-V8.0.2-build0055-FORTINET.tar.gz
  images/
    FAIG_api-V8.0.2-build0055-FORTINET.tar.gz
    FAIG_webui-V8.0.2-build0055-FORTINET.tar.gz
    ...remaining component archives...
```

Preserve original filenames and compression. The license stays on your laptop for upload through the FAIG WebUI later.

The browser uploads use your signed-in AWS identity's permissions. The EC2 role's `AmazonS3ReadOnlyAccess` policy is for downloads and does not authorize uploads from your laptop. If your uploader identity needs an AWS managed S3 policy, an administrator can grant **`AmazonS3FullAccess`**, which also permits modification and deletion across S3 resources; the EC2 role only needs the read-only policy.

With this same-account, SSE-S3 setup, no public access or custom bucket policy is required, provided other account or bucket controls do not deny access. See [AWS browser upload instructions](https://docs.aws.amazon.com/AmazonS3/latest/userguide/upload-objects.html).

## 3. Connect through browser-based SSM

In **EC2 → Instances**:

1. Select the instance.
2. Click **Connect**.
3. Select **Session Manager**.
4. Click **Connect**.

No local AWS CLI or Session Manager plugin is needed for this browser terminal. [AWS connection instructions](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-sessions-start.html)

Run:

```bash
sudo cloud-init status --wait
nvidia-smi
```

Confirm that `nvidia-smi` displays the L40S GPU.

If Session Manager is unavailable after several minutes, check the attached IAM role, public IP, internet gateway route, and outbound rules.

## 4. Prepare Docker

The following mirrors the repository's bootstrap work. Run it before importing any FAIG images.

First check what the AMI provides:

```bash
sudo docker version
docker compose version
```

FAIG requires **Docker Compose 2.23.1 or later**.

If Docker or a sufficiently recent Compose plugin is missing, install them using Docker's repository:

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl

sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo 'deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu jammy stable' \
  | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

sudo apt-get update
sudo apt-get install -y \
  docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin
```

These are the Docker repository installation steps for Ubuntu 22.04. If `apt` reports conflicting distribution packages, follow Docker's conflict-removal instructions before retrying. [Docker installation documentation](https://docs.docker.com/engine/install/ubuntu/)

Next, place Docker's data on the persistent root disk and configure its NVIDIA runtime:

```bash
sudo systemctl stop docker.service docker.socket
sudo install -d -m 0755 /etc/docker

sudo python3 - <<'PY'
import json
from pathlib import Path

path = Path("/etc/docker/daemon.json")
config = json.loads(path.read_text()) if path.exists() else {}
config["data-root"] = "/var/lib/docker"
path.write_text(json.dumps(config, indent=2) + "\n")
PY

sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl enable --now docker
```

The runtime configuration command is NVIDIA's documented Docker setup procedure. [NVIDIA documentation](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)

Verify:

```bash
sudo docker info --format '{{.DockerRootDir}}'
sudo docker info --format '{{json .Runtimes}}'
docker compose version
df -h /var/lib/docker
```

Expect `/var/lib/docker` as the data directory and `nvidia` among the runtimes.

## 5. Create the FAIG operator and download directories

The utility must run as a **non-root user**.

From the SSM terminal:

```bash
sudo useradd --create-home --shell /bin/bash faig
sudo usermod -aG docker faig

sudo install -d -m 0700 -o faig -g faig \
  /home/faig/downloads \
  /home/faig/images \
  /home/faig/deploy-docker-compose

sudo -iu faig
```

You are now operating as `faig`.

## 6. Download the archives from S3 onto the instance

Check for the AWS CLI:

```bash
aws --version
```

If it is missing, install it from this SSM terminal:

```bash
sudo apt-get update
sudo apt-get install -y curl unzip
curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip \
  -o /tmp/faig-awscliv2.zip
unzip -q /tmp/faig-awscliv2.zip -d /tmp/faig-awscli
sudo /tmp/faig-awscli/aws/install
```

As `faig`, replace the bucket placeholder with the actual bucket name, without `s3://`:

```bash
export AWS_DEFAULT_REGION=us-west-2
export FAIG_ARTIFACT_BUCKET='YOUR-BUCKET-NAME'

aws s3 ls "s3://${FAIG_ARTIFACT_BUCKET}/cli/"
aws s3 ls "s3://${FAIG_ARTIFACT_BUCKET}/images/"

aws s3 cp \
  "s3://${FAIG_ARTIFACT_BUCKET}/cli/FAIG_deploy-docker-compose-cli-V8.0.2-build0055-FORTINET.tar.gz" \
  /home/faig/downloads/

aws s3 cp "s3://${FAIG_ARTIFACT_BUCKET}/images/" /home/faig/images/ \
  --recursive --exclude '*' --include '*.tar' --include '*.tar.gz'

ls -lh /home/faig/downloads/ /home/faig/images/
```

The AWS CLI automatically uses the EC2 instance role. There is no need to run `aws configure` or enter access keys. If S3 returns `AccessDenied`, confirm that `AmazonS3ReadOnlyAccess` is attached to the instance role and the bucket is in the same account with SSE-S3 encryption. Allow a short time for newly attached role permissions to propagate.

Confirm that all ten component archives downloaded successfully. The [AWS CLI `s3 cp` reference](https://docs.aws.amazon.com/cli/latest/reference/s3/cp.html) documents recursive copies and filename filters.

The local layout should now be:

```text
/home/faig/downloads/
  FAIG_deploy-docker-compose-cli-V8.0.2-build0055-FORTINET.tar.gz

/home/faig/images/
  FAIG_api-V8.0.2-build0055-FORTINET.tar.gz
  FAIG_webui-V8.0.2-build0055-FORTINET.tar.gz
  ...remaining component archives...
```

The ten component names are:

```text
api
webui
llm-gateway
logd
license_manager
guardrail
guardrail-scanner
custom-triton
faig-models
vllm-server
```

Keep the component archives compressed and preserve their original filenames. The utility recognizes `.tar` and `.tar.gz` archives and imports them itself.

## 7. Extract and launch the utility

As `faig`:

```bash
tar -xzf \
  /home/faig/downloads/FAIG_deploy-docker-compose-cli-V8.0.2-build0055-FORTINET.tar.gz \
  -C /home/faig/deploy-docker-compose \
  deploy-docker-compose.sh USER-GUIDE.md

cd /home/faig/deploy-docker-compose
chmod 0755 deploy-docker-compose.sh

docker info >/dev/null
./deploy-docker-compose.sh --self-test
./deploy-docker-compose.sh
```

The normal launch checks Docker, Compose, memory, disk space, GPU runtime, and network access. Resolve any **FAIL** before proceeding.

Even with all FAIG archives present, the deployment still needs Docker Hub access for supporting images unless those images are preloaded. It also needs access to **`fds1.fortinet.com:443`**.

## 8. Complete the setup wizard

Use these selections:

| Prompt | Selection |
| --- | --- |
| Image source | **1. Release archive folder on this server** |
| Archive folder | **`/home/faig/images`** |
| Release | Select **8.0.2 build0055** |
| HTTPS port | **443** |
| HTTP redirect port | **8081** |
| Bind HTTP redirect to loopback only | **Yes** |
| Enable GPU content inspection | **Yes** |
| GPU selection | Select the single **L40S** |
| LLM gateway memory | **2 GB** |
| Log-retention storage budget | **8 GB** |
| Deployment namespace | **`fortiaigate`** |
| FortiCare proxy | **No**, unless your environment requires one |

Enter the memory and log values explicitly; the bundled utility's defaults may be higher.

For a useful video checkpoint, select:

**5. Images, backup, logs, and diagnostics → 1. Import/verify target images**

Confirm the required images report **PASS**.

Return to the main menu:

1. Choose **3. Deploy or reapply Docker Compose**.
2. Agree to create the required recovery archive.
3. Record the printed archive location and keep it secure; it contains sensitive recovery material.
4. Review the deployment plan.
5. Type **`APPLY`**.

Image imports and model initialization can take time.

Then select **4. Inspect or control the deployment → 1. Status and health**. Repeat after startup settles. Some initialization containers correctly finish with **Exited (0)**.

These menu choices come from the bundled [FAIG user guide](vendor/8.0.2/USER-GUIDE.md).

## 9. Open the WebUI and license FAIG

Copy the instance's **Public IPv4 address** from the EC2 console.

On your own computer, browse to:

```text
https://<instance-public-ip>/ui
```

Use HTTPS port **443**. Accept the lab's self-signed certificate warning.

Complete the administrator and organization setup. When asked for the organization's external URL, use:

```text
https://<instance-public-ip>
```

Upload your `.lic` file through **Licenses**.

Back in the SSM terminal, as `faig`:

```bash
cd /home/faig/deploy-docker-compose

./faig_deployment_assistant_data/deployment/compose.sh restart api
```

Run **Status and health** again and verify licensed functionality.

## 10. Finish the demonstration

Back up anything you want to retain, then **terminate the instance** when finished. The configured root disk is deleted on termination. In the S3 console, select the temporary staging bucket, choose **Empty**, and confirm the deletion of its objects. Then delete the bucket if it is no longer needed. If using an existing shared bucket instead, delete only this deployment's staged objects.

Remove the dedicated security group and IAM role if they are no longer needed. Keep the existing VPC and subnets. If an existing role was reused, remove only the policy attachments added for this demonstration when they are no longer required.

These steps are derived from the repository and checked against AWS's documentation. The archive-based workflow has not been verified with a live deployment as part of preparing this walkthrough.
