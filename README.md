# aws-ec2-isaaclab-soarm101-gui

AWS CDK (TypeScript) stack that provisions an EC2 host for running the Isaac Sim / Isaac Lab GUI via Amazon DCV, used to manually operate the SO-ARM101 arm. **No SSH key, no inbound ports — access is via SSM Session Manager + port forwarding.**

---

## Important: Cost Warning

This stack provisions a GPU-capable EC2 host, which is expensive when left running. Be sure to run the [teardown](#7-teardown-full-deletion) at the end.

| Item | Hourly | If left for 24h |
|--|--|--|
| EC2 `g5.xlarge` (A10G 24GB) | ~$1.30/h | ~$31 (≈ ¥4,700/day) |
| EC2 `t3.medium` (everyday) | ~$0.05/h | ~$1.2 (≈ ¥180/day) |
| EBS gp3 35 GB | $0.096/GB/mo | — (~¥17/day) |
| Public IPv4 (auto-assigned, **released on stop**) | $0.005/h while running | 0 円 while stopped |

**Cost control**:
1. **t3 ↔ g5 swap**: everyday work on `t3.medium`, switch to `g5.xlarge` only when GPU is needed
2. **Full teardown**: `pnpm cdk destroy`
3. **Close Isaac Sim and stop when away** (CPU-based auto-stop is NOT used: Isaac Sim keeps CPU at ~70% even when idle, so a CPU threshold can't tell "in use" from "left running". A notify-based stop is planned for a separate article.)

---

## 1. Prerequisites

- AWS account with `Running On-Demand G and VT instances` quota ≥ 4 vCPU in `ap-northeast-1`
- `pnpm` (npm/npx are not used)
- AWS CLI v2 with credentials configured
- **AWS Session Manager Plugin** ([install guide](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html))
- Node.js 20+
- CDK bootstrap permission on first use

> No SSH key pair or allowed CIDR is required by this stack. All access is via SSM Session Manager.

## 2. Architecture

- VPC (single AZ `ap-northeast-1a`, public subnet only, no NAT)
- Security Group (**no inbound rules**, egress only)
- IAM Role (`AmazonSSMManagedInstanceCore` + S3 read for DCV license / NVIDIA driver)
- EC2 Instance (initial `t3.medium`, Ubuntu 22.04 LTS, **EBS gp3 35 GB** — online-expandable)
- Public IPv4 is **auto-assigned** (no EIP; needed only for the SSM agent's egress to the AWS API). IP changes across stop/start, but access is via SSM so this does not matter.

## 3. Deploy

```bash
git clone https://github.com/furuya02/aws-ec2-isaaclab-soarm101-gui.git
cd aws-ec2-isaaclab-soarm101-gui/cdk
pnpm install

# First time only
pnpm exec cdk bootstrap

# Deploy (no context needed)
pnpm exec cdk deploy
```

Outputs after deploy:

- `InstanceId` — stable across stop/start
- `SsmStartCommand` — interactive shell via SSM Session Manager
- `DcvPortForwardCommand` — `localhost:8443` → `EC2:8443` for DCV browser access

## 4. Smoke test (SSM)

`scripts/connect.sh` resolves the InstanceId by Name tag and opens an SSM session:

```bash
./scripts/connect.sh
```

Manual alternative:

```bash
aws ssm start-session --target <InstanceId> --region ap-northeast-1
```

The instance starts as `t3.medium` (no GPU), so `nvidia-smi` is not available yet. Use this state to install Docker and prepare code.

## 4.1 Provided scripts

| Script | Run on | Purpose |
|--|--|--|
| `scripts/connect.sh` | local PC | Open SSM interactive shell (InstanceId by Name tag) |
| `scripts/dcv-port-forward.sh` | local PC | Port-forward `localhost:8443` → `EC2:8443` via SSM |
| `scripts/setup-docker.sh` | EC2 (t3 is fine) | Docker + NVIDIA Container Toolkit |
| `scripts/switch-to-g5.sh` | local PC | t3.medium → g5.xlarge |
| `scripts/setup-dcv.sh` | EC2 (g5) | NVIDIA CUDA Datacenter Driver 570 + Amazon DCV Server |
| `scripts/setup-isaac.sh` | EC2 (g5) | NGC login + Isaac Sim pull + isaac_so_arm101 clone |
| `scripts/launch-isaac.sh` | EC2 (g5, **DCV desktop terminal**) | One-shot Isaac Sim Native GUI launcher (kit + isaacsim.exp.full.kit, `--clear-cache` option) |
| `scripts/switch-to-t3.sh` | local PC | g5.xlarge → t3.medium |
| `scripts/teardown.sh` | local PC | cdk destroy + leftover check |

End-to-end run order:

1. `pnpm exec cdk deploy` from `cdk/` (billing starts)
2. `./scripts/connect.sh` to open SSM session
3. On EC2: `./setup-docker.sh`, then exit and reconnect
4. From local: `./scripts/switch-to-g5.sh`
5. `./scripts/connect.sh` again (now g5)
6. On EC2: `./setup-dcv.sh`, then `sudo reboot`
7. **In a separate terminal**: `./scripts/dcv-port-forward.sh` (tunnel)
8. Open `https://localhost:8443` in a browser (DCV)
9. In the DCV desktop terminal: `./setup-isaac.sh`
10. In the same DCV terminal: `./scripts/launch-isaac.sh` to launch Isaac Sim Native GUI; then import URDF and drive joints with Physics Inspector
11. From local: `./scripts/switch-to-t3.sh` when done
12. `./scripts/teardown.sh` to fully destroy

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

## 6. About idle protection

A CPU-based auto-stop (CloudWatch Alarm) is **not used**. While Isaac Sim is running, the CPU stays at ~70% even when idle, so a "CPU < 2%" threshold cannot distinguish "in use" from "left running".

For now, rely on operational habits:

- **Switch back to t3.medium with `switch-to-t3.sh` when the GPU is not needed** (cheaper for everyday work)
- **Close Isaac Sim and stop the EC2 instance when you step away / finish**
- **Run the teardown below if you won't use it for a while**

A notify-based stop (LINE / email "continue or stop") is planned for a separate article.

## 7. Teardown (full deletion)

```bash
cd aws-ec2-isaaclab-soarm101-gui/cdk
pnpm exec cdk destroy --force
```

Then confirm no leftovers (no EIP check needed — EIP is not created by this stack):

```bash
aws ec2 describe-instances --filters Name=tag:Name,Values=aws-ec2-isaaclab-soarm101-gui-instance
aws ec2 describe-volumes --filters Name=tag:Name,Values=aws-ec2-isaaclab-soarm101-gui-instance
```

Also check Cost Explorer the next day to confirm billing has stopped.

A Japanese version of this README is available at [README.ja.md](./README.ja.md).

## Real-world verification notes (2026/05/18 + 2026/05/19)

`scripts/setup-dcv.sh` and `scripts/setup-isaac.sh` have been updated to reflect the verified working configuration.

### Verified working configuration

| Item | Value |
|--|--|
| Instance (**primary recommendation**) | **g5.xlarge (A10G 24GB)** ≈ ~$1.30/h |
| Instance (alternative) | g6e.xlarge (L40S 48GB) ≈ ~$2.42/h, g6.xlarge (L4 24GB) ≈ ~$1.32/h (L4 untested) |
| AMI | Ubuntu 22.04.5 LTS HVM |
| NVIDIA Driver | **CUDA Datacenter driver 570** (`nvidia-driver-570`) |
| Amazon DCV | 2025.0 (Ubuntu 22.04 x86_64) |
| Isaac Sim | 5.1.0-rc.19 (`nvcr.io/nvidia/isaac-sim:5.1.0`) |

### Key gotchas (candidates for the article's "stuck points" section)

1. **GRID driver does NOT work with Isaac Sim 5.1.0** (always crashes at `librtx.scenedb`). AWS DCV documentation generally recommends the GRID driver, but for Isaac Sim you need **CUDA Datacenter driver `nvidia-driver-570`** (applied in `setup-dcv.sh`).
2. **`nvidia-xconfig` is not bundled with the CUDA driver package**. The `xorg.conf` must be written by hand, including `AllowEmptyInitialConfiguration "True"` (applied in `setup-dcv.sh`).
3. **`./isaac-sim.sh` launches the Streaming experience by default**. To get a Native Desktop GUI, invoke `--entrypoint /isaac-sim/kit/kit` + `/isaac-sim/apps/isaacsim.exp.full.kit` directly (printed by `setup-isaac.sh`).
4. **URDF Import requires write permission on `~/work`** (`sudo chmod -R a+rwX ~/work/`, applied in `setup-isaac.sh`). The container runs as root and writes the converted USD next to the URDF.
5. **Clear the cache when switching GPU type** (an L40S-built shader cache will hang `omni.kit.registry.nucleus` on A10G):
   ```bash
   rm -rf ~/docker/isaac-sim/{kit-cache,ov-cache,gl-cache,compute-cache,logs}
   ```
6. **Physics Inspector** opens with a "Re-Enable authoring" button — click it to reparse the articulation.
7. **`xhost +local:docker` does NOT work from an SSH terminal** (no `DISPLAY`). Run it **inside the DCV desktop terminal**, or `export DISPLAY=:0` first.

### Verification matrix

| GPU | driver | cache | Result |
|--|--|--|--|
| L40S (g6e) | GRID 595 | — | ❌ librtx crash |
| L40S (g6e) | CUDA 570 | fresh | ✅ works |
| A10G (g5) | CUDA 570 | leftover L40S cache | ❌ nucleus hang |
| **A10G (g5)** | **CUDA 570** | **cleared** | ✅ **fully working (recommended)** |

## License

MIT
