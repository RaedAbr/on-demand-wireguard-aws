# On-demand WireGuard VPN on AWS

Run your own WireGuard VPN server in the country you choose, and only while you need it. Pick a region in GitHub Actions and tap **Run workflow**: the whole stack is built from scratch in a few minutes. Run it again with `down` and everything is deleted, so an idle VPN costs nothing.

It works from a browser or from the GitHub mobile app, and your WireGuard keys stay the same across deployments and regions.

> **AWS only.** This project currently supports Amazon Web Services and no other cloud provider.

## Video walkthrough

[![Watch the video walkthrough on YouTube](https://img.youtube.com/vi/l6I3FHUyjmU/maxresdefault.jpg)](https://youtu.be/l6I3FHUyjmU)

This 6-minute video shows how to start the VPN, connect to it and shut it down. It assumes you've finished the [setup](#setup). Subtitles are available in English, French, German and Arabic.

## Features

- **Choose your exit country** from a dropdown of 33 AWS regions. For an exit in France, pick `France (Paris) - eu-west-3`.
- **Up / down from your phone** through a manual GitHub Actions workflow.
- **Nothing left running:** `down` removes the instance, disk, public IP, network and SSH key pair.
- **Stable keys:** one client configuration works everywhere. Only the endpoint changes.
- **Optional stable hostname** through [DuckDNS](https://www.duckdns.org), so you don't have to update the endpoint.

## How it works

[OpenTofu](https://opentofu.org) creates the following in the selected region:

| Resource | Details |
| :--- | :--- |
| VPC, public subnet, internet gateway, route table | Dedicated network (`10.10.0.0/16`) |
| Security group | WireGuard UDP port open to all, SSH limited to the CIDRs you allow |
| EC2 key pair | Built from your SSH public key |
| EC2 instance | `t3.micro`, Ubuntu 26.04 LTS, 8 GB gp3 disk |

On first boot, cloud-init installs WireGuard, turns on IP forwarding and NAT, and writes `wg0.conf`.

The only thing that outlives `down` is the S3 bucket holding the OpenTofu state. Each region has its own state file, at `wireguard-vpn/<region>/terraform.tfstate`.

## Setup

You need an AWS account, a GitHub account, and these tools on your computer: [AWS CLI](https://aws.amazon.com/cli/) and `wireguard-tools` (for `wg`).

### 1. Copy the repository

Create your own **private** copy of this repository (recommended, see [Security notes](#security-notes)), or fork it. In a fork, open the **Actions** tab and enable workflows.

You don't need to edit any code. All your settings go in GitHub in step 5.

### 2. Create the state bucket

Bucket names are global, so pick a unique one. The bucket can be in any region, and it doesn't have to match where your VPN runs.

```bash
BUCKET=my-wireguard-tfstate-12345
REGION=eu-west-3

aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
  --create-bucket-configuration LocationConstraint="$REGION"
aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled
```

### 3. Create an IAM user

Create a dedicated IAM user with an access key and this policy, replacing `BUCKET`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": "ec2:*", "Resource": "*" },
    { "Effect": "Allow", "Action": "s3:ListBucket", "Resource": "arn:aws:s3:::BUCKET" },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::BUCKET/wireguard-vpn/*"
    }
  ]
}
```

If you restrict this user by region (for example with an `aws:RequestedRegion` condition), the condition must list every region you want to use, plus the bucket's region.

### 4. Generate WireGuard keys

```bash
wg genkey | tee server.key | wg pubkey > server.pub
wg genkey | tee client.key | wg pubkey > client.pub
wg genpsk > client.psk
```

Keep these files safe and out of Git.

### 5. Add your GitHub settings

Go to **Settings → Secrets and variables → Actions**. Secrets go in the **Secrets** tab and variables in the **Variables** tab.

**Secrets** (hidden in logs)

| Secret | Value | Required |
| :--- | :--- | :--- |
| `AWS_ACCESS_KEY_ID` | Access key of the IAM user | Yes |
| `AWS_SECRET_ACCESS_KEY` | Secret key of the IAM user | Yes |
| `TF_STATE_BUCKET` | Name of your state bucket | Yes |
| `WG_SERVER_PRIVATE_KEY` | Contents of `server.key` | Yes |
| `WG_CLIENT_PRESHARED_KEY` | Contents of `client.psk` | Yes |
| `SSH_ALLOWED_CIDRS` | JSON list of allowed IPs, such as `["203.0.113.7/32"]` | No |
| `DUCKDNS_DOMAIN` | Subdomain, without `.duckdns.org` | No |
| `DUCKDNS_TOKEN` | DuckDNS token | No |

**Variables** (can appear in logs)

| Variable | Value | Required |
| :--- | :--- | :--- |
| `TF_STATE_REGION` | Region of your state bucket, such as `eu-west-3` | Yes |
| `WG_CLIENT_PUBLIC_KEY` | Contents of `client.pub` | Yes |
| `SSH_PUBLIC_KEY` | Your SSH public key | No |

SSH access is optional. To use it, set both `SSH_PUBLIC_KEY` and `SSH_ALLOWED_CIDRS`. Without `SSH_ALLOWED_CIDRS`, port 22 stays closed.

### 6. Configure your WireGuard client

Create a tunnel in the WireGuard app with this configuration:

```ini
[Interface]
PrivateKey = <contents of client.key>
Address = 10.66.66.2/32, fd42:42:42::2/128
DNS = 1.1.1.1

[Peer]
PublicKey = <contents of server.pub>
PresharedKey = <contents of client.psk>
Endpoint = <shown after each deployment>
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
```

## Usage

### Start the VPN

1. Open **Actions → WireGuard VPN Control (Up / Down) → Run workflow**.
2. Set **action** to `up` and choose a **region**.
3. When the run finishes, copy the endpoint from the run summary into your client, unless you use DuckDNS.
4. Wait a minute or two for the server to finish its first boot, then activate the tunnel.

### Stop the VPN

Run the workflow with **action** set to `down` and the **same region** you deployed to. The run list shows the action and region of every past run, so you can check there.

If you pick a region with nothing deployed, the run ends with a "Nothing to destroy" warning. Any server in another region **keeps running and keeps costing money**, so re-run `down` with the right region.

### Regions

Regions marked `[opt-in]` are off by default in AWS accounts. Turn them on under **AWS console → Account → AWS Regions** before you use them. This can take a few minutes.

| Available by default | Opt-in required |
| :--- | :--- |
| Australia (Sydney), Brazil, Canada (Montreal), France, Germany, Ireland, India (Mumbai), Japan (Tokyo, Osaka), Singapore, South Korea, Sweden, UK, USA (N. Virginia, Ohio, N. California, Oregon) | Australia (Melbourne), Canada (Calgary), Hong Kong, India (Hyderabad), Indonesia, Israel, Italy, Malaysia, Mexico, New Zealand, South Africa, Spain, Switzerland, Taiwan, Thailand, UAE |

Regions are independent, so you can run servers in several at once, each with its own endpoint. The keys are shared, so use only one tunnel at a time. With DuckDNS, the hostname points to the most recently started server.

To add a region, add a line to the `region` options in [`vpn-control.yml`](.github/workflows/vpn-control.yml), keeping the region id as the last word.

## Costs

You pay AWS only while the server exists: the instance, its public IPv4 address, the disk and outbound traffic. Expect roughly 1 to 2 US cents per hour plus traffic, depending on the region. See [EC2 pricing](https://aws.amazon.com/ec2/pricing/on-demand/) for current prices. The state bucket costs almost nothing.

## Running locally

You can use OpenTofu without GitHub Actions. Put your keys in `terraform.tfvars` (see [`terraform.tfvars.example`](terraform.tfvars.example)), then pass the VPN region twice: once for the state file and once for the deployment.

```bash
BUCKET=my-wireguard-tfstate-12345
BUCKET_REGION=eu-west-3
REGION=eu-west-3

tofu init -reconfigure \
  -backend-config="bucket=${BUCKET}" \
  -backend-config="region=${BUCKET_REGION}" \
  -backend-config="key=wireguard-vpn/${REGION}/terraform.tfstate"
tofu apply -var="aws_region=${REGION}"
tofu destroy -var="aws_region=${REGION}"
```

Always use matching values. There is deliberately no default state key, so `tofu init` fails or prompts without one.

## Security notes

- **Run logs are public in a public repository.** Anyone can read your server's IP address and instance ID in the run summary and logs. Keys stay hidden, but a private copy is the better choice for personal use.
- **Only people with write access can run the workflow.** Visitors to a public repository can't start or stop your server.
- **The WireGuard private key is stored in the EC2 user data**, so anyone with EC2 read access to your AWS account can read it while the server exists.
- **Keep the state bucket private.** Never commit `terraform.tfvars` or your key files.

## Limitations

- AWS only.
- One client per deployment. More devices need changes to the `[Peer]` section in `main.tf`.
- Traffic exits over IPv4 only, because the VPC has no IPv6. Keeping `::/0` in the client config stops IPv6 traffic from bypassing the tunnel.
- AWS IP addresses are often recognised as data center traffic, so some streaming services and websites may block them.

## Troubleshooting

| Symptom | Likely cause |
| :--- | :--- |
| `AuthFailure` or an STS error during `up` | The region is `[opt-in]` and not enabled in your account |
| `UnauthorizedOperation` | The IAM policy doesn't allow this region |
| Error saying the instance type isn't offered | Set a different `instance_type` default in `variables.tf` |
| `Set the TF_STATE_BUCKET secret...` | A required setting from step 5 is missing |
| `wg_client_public_key must be a WireGuard public key` | The `WG_CLIENT_PUBLIC_KEY` variable is missing or wrong |
| Tunnel is on but no traffic flows | The first boot isn't finished, or the endpoint is out of date |

If you set up SSH, you can inspect the server with `ssh -i <your-private-key> ubuntu@<public-ip>`, then run `sudo wg show` and `sudo cat /var/log/cloud-init-output.log`.

## License

[MIT](LICENSE)
