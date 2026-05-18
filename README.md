# aws-ec2-isaaclab-soarm101-gui

AWS CDK (TypeScript) stack that provisions an EC2 host for running the Isaac Sim / Isaac Lab GUI via NICE DCV, used to manually operate the SO-ARM101 arm.

---

## Important: Cost Warning

This stack provisions a GPU-capable EC2 host, which is expensive when left running. Be sure to run the [teardown](#7-teardown-full-deletion) at the end.

| Item | Hourly | If left for 24h |
|--|--|--|
| EC2 `g5.xlarge` (A10G 24GB) | ~$1.30/h | ~$31 (≈ ¥4,700/day) |
| EC2 `t3.medium` (everyday) | ~$0.05/h | ~$1.2 (≈ ¥180/day) |
| EBS gp3 50 GB | $0.10/GB/mo | — |
| Elastic IP (billed even when stopped) | $0.005/h | ~$0.12/day |

**Triple defense**:
1. **CloudWatch Alarm**: auto-stops the instance after 30 minutes of CPU < 2% (built into this stack)
2. **t3 ↔ g5 swap**: everyday work on `t3.medium`, switch to `g5.xlarge` only when GPU is needed
3. **Full teardown**: `pnpm cdk destroy`

---

## 1. Prerequisites

- AWS account with `Running On-Demand G and VT instances` quota ≥ 4 vCPU in `ap-northeast-1`
- Existing EC2 key pair in `ap-northeast-1` (examples below use `ec2-key`)
- `pnpm` (npm/npx are not used)
- AWS CLI v2 with credentials configured
- Node.js 20+
- CDK bootstrap permission on first use

## 2. Architecture

- VPC (single AZ `ap-northeast-1a`, public subnet only, no NAT)
- Security Group (SSH 22, NICE DCV TCP+UDP 8443, restricted to the supplied CIDR)
- IAM Role (SSM Session Manager + S3 read for DCV license / NVIDIA GRID driver)
- EC2 Instance (initial `t3.medium`, Ubuntu 22.04 LTS, EBS gp3 50 GB, attached EIP)
- CloudWatch Alarm (CPU < 2% × 30 min → native EC2 Stop action, no Lambda)

## 3. Deploy

```bash
git clone https://github.com/furuya02/aws-ec2-isaaclab-soarm101-gui.git
cd aws-ec2-isaaclab-soarm101-gui/cdk
pnpm install

# First time only
pnpm exec cdk bootstrap

# Discover your global IP
MY_IP=$(curl -s https://checkip.amazonaws.com)
echo "${MY_IP}/32"

# Deploy (keypair name and allowed CIDR are required)
pnpm exec cdk deploy \
  -c keypair_name=ec2-key \
  -c allowed_cidr=${MY_IP}/32
```

Outputs after deploy:

- `InstanceId`
- `PublicIp` (Elastic IP)
- `SshCommand`
- `SsmStartCommand`
- `DcvUrl` (use after DCV is installed on the g5 instance)

## 4. Smoke test (SSH)

`scripts/connect.sh` discovers the Public IP and SSHs in:

```bash
./scripts/connect.sh
```

Manual alternative:

```bash
ssh -i ~/.ssh/ec2-key.pem ubuntu@<PublicIp>
```

The instance starts as `t3.medium` (no GPU), so `nvidia-smi` is not available yet. Use this state to install Docker and prepare code.

## 4.1 Provided scripts

| Script | Run on | Purpose |
|--|--|--|
| `scripts/connect.sh` | local PC | SSH connect helper (auto Public IP) |
| `scripts/setup-docker.sh` | EC2 (t3 is fine) | Docker + NVIDIA Container Toolkit |
| `scripts/switch-to-g5.sh` | local PC | t3.medium → g5.xlarge |
| `scripts/setup-dcv.sh` | EC2 (g5) | NVIDIA GRID Driver + Amazon DCV Server |
| `scripts/setup-isaac.sh` | EC2 (g5) | NGC login + Isaac Sim pull + isaac_so_arm101 clone |
| `scripts/switch-to-t3.sh` | local PC | g5.xlarge → t3.medium |
| `scripts/teardown.sh` | local PC | cdk destroy + leftover check |

End-to-end run order:

1. `pnpm exec cdk deploy` from `cdk/` (billing starts)
2. `./scripts/connect.sh` to SSH
3. On EC2: `./setup-docker.sh`, then exit and re-SSH
4. From local: `./scripts/switch-to-g5.sh`
5. `./scripts/connect.sh` again (now g5)
6. On EC2: `./setup-dcv.sh`, then `sudo reboot`
7. Open `https://<PublicIp>:8443` in a browser (DCV)
8. In the DCV desktop terminal: `./setup-isaac.sh`
9. Launch Isaac Sim with the `docker run` shown by `setup-isaac.sh`, import URDF, drive joints with Physics Inspector
10. From local: `./scripts/switch-to-t3.sh` when done
11. `./scripts/teardown.sh` to fully destroy

## 5. Switch instance type (t3 ↔ g5)

Switch to `g5.xlarge` only while the GPU is needed (e.g. running Isaac Sim GUI), then switch back.

### t3.medium → g5.xlarge

```bash
INSTANCE_ID=<InstanceId>
aws ec2 stop-instances --instance-ids ${INSTANCE_ID}
aws ec2 wait instance-stopped --instance-ids ${INSTANCE_ID}
aws ec2 modify-instance-attribute --instance-id ${INSTANCE_ID} --instance-type g5.xlarge
aws ec2 start-instances --instance-ids ${INSTANCE_ID}
```

### g5.xlarge → t3.medium (do this right after work to save cost)

```bash
aws ec2 stop-instances --instance-ids ${INSTANCE_ID}
aws ec2 wait instance-stopped --instance-ids ${INSTANCE_ID}
aws ec2 modify-instance-attribute --instance-id ${INSTANCE_ID} --instance-type t3.medium
aws ec2 start-instances --instance-ids ${INSTANCE_ID}
```

EBS is shared, so installed packages and Docker images persist across the swap.

## 6. CloudWatch Alarm (Auto Stop)

This stack creates the alarm `aws-ec2-isaaclab-soarm101-gui-idle-stop`:

- Condition: average CPU < 2% for 30 minutes (6 × 5-min periods)
- Action: native EC2 Stop (not terminate — EBS is preserved)

It catches forgotten shutdowns (e.g. left the GUI running and walked away).

> Stop preserves EBS so you can resume. For full cleanup, run the next step.

## 7. Teardown (full deletion)

```bash
cd aws-ec2-isaaclab-soarm101-gui/cdk
pnpm exec cdk destroy --force
```

Then confirm no leftovers:

```bash
aws ec2 describe-instances --filters Name=tag:Name,Values=aws-ec2-isaaclab-soarm101-gui-instance
aws ec2 describe-addresses --filters Name=tag:Name,Values=aws-ec2-isaaclab-soarm101-gui-eip
aws ec2 describe-volumes --filters Name=tag:Name,Values=aws-ec2-isaaclab-soarm101-gui-instance
```

Also check Cost Explorer the next day to confirm billing has stopped.

A Japanese version of this README is available at [README.ja.md](./README.ja.md).

## Real-world verification notes (2026/05/18)

The `cdk/` and `scripts/` in this repo are the initial scaffold. End-to-end testing revealed the **actual working configuration** below, which is **not yet reflected** in the scripts. To be incorporated in a follow-up commit.

### Verified working configuration

| Item | Value |
|--|--|
| Instance | **g6e.xlarge (L40S)** (g5 = A10G, g6 = L4 not yet tested) |
| AMI | Ubuntu 22.04.5 LTS HVM |
| NVIDIA Driver | **CUDA Datacenter driver 570** (`nvidia-driver-570`) |
| Amazon DCV | 2025.0 (Ubuntu 22.04 x86_64) |
| Isaac Sim | 5.1.0-rc.19 (`nvcr.io/nvidia/isaac-sim:5.1.0`) |

### Key gotchas and fixes

1. **GRID driver does not work with Isaac Sim 5.1.0** (always crashes at `librtx.scenedb`). `scripts/setup-dcv.sh` installs GRID driver but needs to be replaced with CUDA Datacenter driver.
2. **`nvidia-xconfig` is not bundled with the CUDA driver package**. Write `xorg.conf` by hand (include `AllowEmptyInitialConfiguration "True"`).
3. **`./isaac-sim.sh` launches the Streaming experience by default**. To get a Native GUI window, invoke `./kit/kit /isaac-sim/apps/isaacsim.exp.full.kit` directly (the `--experience` argument is ignored internally).
4. **URDF Import requires write permission on the host `~/work` tree** (`sudo chmod -R a+rwX ~/work/`). The container runs as root and writes the converted USD next to the URDF.
5. **Physics Inspector** opens with `[No selection]` and a "Re-Enable authoring" button. Click it to reparse the articulation.

### Working `docker run` command (run inside the DCV desktop terminal)

```bash
xhost +local:docker
docker rm -f isaac-sim 2>/dev/null

docker run --name isaac-sim --rm \
  --runtime=nvidia --gpus all \
  --ipc=host --network=host \
  -e DISPLAY=${DISPLAY} -e ACCEPT_EULA=Y -e PRIVACY_CONSENT=Y \
  -v /tmp/.X11-unix:/tmp/.X11-unix \
  -v ${HOME}/work:/work \
  -v ${HOME}/docker/isaac-sim/kit-cache:/isaac-sim/kit/cache:rw \
  -v ${HOME}/docker/isaac-sim/ov-cache:/root/.cache/ov:rw \
  -v ${HOME}/docker/isaac-sim/gl-cache:/root/.cache/nvidia/GLCache:rw \
  -v ${HOME}/docker/isaac-sim/compute-cache:/root/.nv/ComputeCache:rw \
  -v ${HOME}/docker/isaac-sim/logs:/root/.nvidia-omniverse/logs:rw \
  --entrypoint /isaac-sim/kit/kit \
  nvcr.io/nvidia/isaac-sim:5.1.0 \
  /isaac-sim/apps/isaacsim.exp.full.kit
```

### To-be-verified next

- Whether g5.xlarge (A10G) also works with CUDA driver 570
- If it does, update `scripts/` to reflect the actual working steps (GRID → CUDA driver, kit invocation, chmod, apt sources, etc.)

## License

MIT
