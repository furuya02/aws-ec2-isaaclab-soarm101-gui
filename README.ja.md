# aws-ec2-isaaclab-soarm101-gui

AWS EC2 + NICE DCV で Isaac Sim / Isaac Lab の GUI を起動し、SO-ARM101 を手動操作するためのインフラ一式（AWS CDK / TypeScript）。

---

## 重要: コスト警告

このスタックは **GPU 付き EC2 を扱うため放置すると高額**になります。必ず最後に [削除手順](#7-削除完全) を実行してください。

| 項目 | 単価 | 24h 放置 |
|--|--|--|
| EC2 `g5.xlarge` (A10G 24GB) | 約 $1.30/h ≒ 約 195 円/h | 約 $31 ≒ **約 4,700 円/日** |
| EC2 `t3.medium`（普段） | 約 $0.05/h ≒ 約 7.5 円/h | 約 $1.2 ≒ 約 180 円/日 |
| EBS gp3 35 GB | $0.096/GB/月 | 約 17 円/日 |
| Public IPv4（自動付与、**停止時は解放**） | $0.005/h（起動中のみ） | **停止中 0 円** |

**3 重防御**:
1. **CloudWatch Alarm**: CPU < 2% × 連続 30 分で **自動 Stop**（本スタックで標準装備）
2. **t3 ↔ g5 切替運用**: 普段は t3.medium、GPU 必要時のみ g5.xlarge
3. **完全削除手順**: `pnpm cdk destroy`

---

## 1. 前提

- AWS アカウント（ap-northeast-1 で `Running On-Demand G and VT instances` クォータが 4 vCPU 以上）
- 既存の EC2 キーペア（ap-northeast-1 に登録済み、本 README では `ec2-key` を例とします）
- `pnpm`（npm/npx は使用しません）
- AWS CLI v2（認証は `~/.aws/credentials` または環境変数）
- Node.js 20 以上
- CDK が初回利用なら `cdk bootstrap` 実行可能なこと

## 2. アーキテクチャ

- VPC（`ap-northeast-1a` 1 AZ, public subnet のみ, NAT なし）
- Security Group（SSH 22 / DCV TCP+UDP 8443 を **指定 CIDR のみ許可**）
- IAM Role（SSM Session Manager + DCV ライセンス / NVIDIA GRID ドライバ S3 Read）
- EC2 Instance（初期 `t3.medium`、Ubuntu 22.04 LTS、**EBS gp3 35 GB**、オンライン拡張可）
- Public IPv4 は**自動付与**（EIP 不使用）。stop/start のたびに IP が変わるため、`./scripts/connect.sh` か `aws ec2 describe-instances` で live IP を確認する。
- CloudWatch Alarm（CPU < 2% × 30 分 → **EC2 ネイティブ Stop アクション**、Lambda 不要）

## 3. 構築

```bash
git clone https://github.com/furuya02/aws-ec2-isaaclab-soarm101-gui.git
cd aws-ec2-isaaclab-soarm101-gui/cdk
pnpm install

# 初回のみ
pnpm exec cdk bootstrap

# 自分のグローバル IP を確認
MY_IP=$(curl -s https://checkip.amazonaws.com)
echo "${MY_IP}/32"

# デプロイ（キーペア名と許可 CIDR を必ず指定）
pnpm exec cdk deploy \
  -c keypair_name=ec2-key \
  -c allowed_cidr=${MY_IP}/32
```

デプロイ完了後、Outputs には以下のみが表示されます（EIP を使っておらず Public IP は stop/start で変わるため、固定 IP として Output には載せていません）:

- `InstanceId` — stop/start で不変
- `SsmStartCommand` — IP に依存しない SSM Session Manager コマンド

live な Public IP（SSH / DCV URL）の取得方法:

```bash
# SSH（Name タグから現在の Public IP を引いて接続）
./scripts/connect.sh

# DCV URL
PUBLIC_IP=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=aws-ec2-isaaclab-soarm101-gui-instance" \
            "Name=instance-state-name,Values=running" \
  --region ap-northeast-1 \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
echo "https://${PUBLIC_IP}:8443"
```

## 4. 動作確認（SSH 接続）

`scripts/connect.sh` が PublicIp を自動取得して SSH 接続します:

```bash
./scripts/connect.sh
```

手動で接続するなら:

```bash
ssh -i ~/.ssh/ec2-key.pem ubuntu@<PublicIp>
```

初期状態は `t3.medium`（GPU なし）なので `nvidia-smi` は使えません。Docker・コードの準備等はここで実施します。

## 4.1 提供スクリプト一覧

| スクリプト | 実行場所 | 役割 |
|--|--|--|
| `scripts/connect.sh` | ローカル PC | 現在の Public IP を Name タグから引いて SSH 接続 |
| `scripts/setup-docker.sh` | EC2 (t3 で OK) | Docker + NVIDIA Container Toolkit |
| `scripts/switch-to-g5.sh` | ローカル PC | t3.medium → g5.xlarge |
| `scripts/setup-dcv.sh` | EC2 (g5) | NVIDIA CUDA Datacenter Driver 570 + Amazon DCV Server |
| `scripts/setup-isaac.sh` | EC2 (g5) | NGC login + Isaac Sim pull + isaac_so_arm101 clone |
| `scripts/launch-isaac.sh` | EC2 (g5、**DCV デスクトップ内ターミナル**) | Isaac Sim Native GUI を 1 行で起動（kit + isaacsim.exp.full.kit、`--clear-cache` オプション付き） |
| `scripts/switch-to-t3.sh` | ローカル PC | g5.xlarge → t3.medium |
| `scripts/teardown.sh` | ローカル PC | cdk destroy + 残留リソース確認 |

エンドツーエンドの想定実行順:

1. `cdk/` で `pnpm exec cdk deploy` （構築、課金開始）
2. `./scripts/connect.sh` で SSH
3. EC2 上で `./setup-docker.sh` 実行 → 一度 SSH 抜けて再接続
4. ローカルから `./scripts/switch-to-g5.sh` で g5 切替
5. `./scripts/connect.sh` で SSH（g5）
6. EC2 上で `./setup-dcv.sh` → 終了後 `sudo reboot`
7. ブラウザで `https://<PublicIp>:8443`（DCV 接続）
8. DCV デスクトップのターミナルで `./setup-isaac.sh`
9. 同じ DCV ターミナルで `./scripts/launch-isaac.sh` で Isaac Sim Native GUI を 1 行起動 → URDF Import → Physics Inspector で操作
10. 終わったらローカルから `./scripts/switch-to-t3.sh` で t3 戻し
11. 完了時 `./scripts/teardown.sh` で完全削除

## 5. インスタンスタイプ切替（t3 ↔ g5）

GPU が必要なとき（GUI 起動・Isaac Sim 操作時）のみ `g5.xlarge` に切り替えます。

### t3.medium → g5.xlarge

```bash
INSTANCE_ID=<InstanceId>
aws ec2 stop-instances --instance-ids ${INSTANCE_ID}
aws ec2 wait instance-stopped --instance-ids ${INSTANCE_ID}
aws ec2 modify-instance-attribute --instance-id ${INSTANCE_ID} --instance-type g5.xlarge
aws ec2 start-instances --instance-ids ${INSTANCE_ID}
```

### g5.xlarge → t3.medium（コスト削減のため作業後すぐに）

```bash
aws ec2 stop-instances --instance-ids ${INSTANCE_ID}
aws ec2 wait instance-stopped --instance-ids ${INSTANCE_ID}
aws ec2 modify-instance-attribute --instance-id ${INSTANCE_ID} --instance-type t3.medium
aws ec2 start-instances --instance-ids ${INSTANCE_ID}
```

EBS は共通なので、インストール済みパッケージ・Docker イメージはそのまま引き継がれます。

## 6. CloudWatch Alarm（Auto Stop）

本スタックでは以下のアラームを自動作成します:

- **名前**: `aws-ec2-isaaclab-soarm101-gui-idle-stop`
- **条件**: CPU 平均使用率 < 2% が 連続 30 分（5 分 × 6 回）
- **アクション**: EC2 ネイティブ Stop（terminate ではなく Stop、EBS は残る）

「GUI 起動したまま PC を離れた」「作業終了後に止め忘れた」といった低負荷状態を自動検知して止めます。

> Stop は EBS を残すため、後で再開可能です。**完全削除は次節**を実行してください。

## 7. 削除（完全）

```bash
cd aws-ec2-isaaclab-soarm101-gui/cdk
pnpm exec cdk destroy --force
```

削除後、以下を確認してください:

```bash
# EC2 / EBS の残留がないこと（EIP は元々作っていないので確認不要）
aws ec2 describe-instances --filters Name=tag:Name,Values=aws-ec2-isaaclab-soarm101-gui-instance
aws ec2 describe-volumes --filters Name=tag:Name,Values=aws-ec2-isaaclab-soarm101-gui-instance
```

翌日 Cost Explorer で当該リソースの課金が 0 円になっていることも確認してください。

## 実機検証メモ（2026/05/18 + 2026/05/19）

`scripts/setup-dcv.sh` と `scripts/setup-isaac.sh` は実機検証で判明した **動作する設定** に修正済みです。

### 動作確認済構成

| 項目 | 値 |
|--|--|
| インスタンス（**第一推奨**） | **g5.xlarge (A10G 24GB)** ≒ 約 195 円/h |
| インスタンス（代替） | g6e.xlarge (L40S 48GB) ≒ 約 363 円/h、g6.xlarge (L4 24GB) ≒ 約 200 円/h（L4 は未検証） |
| AMI | Ubuntu 22.04.5 LTS HVM |
| NVIDIA Driver | **CUDA Datacenter driver 570** (`nvidia-driver-570`) |
| Amazon DCV | 2025.0（Ubuntu 22.04 x86_64） |
| Isaac Sim | 5.1.0-rc.19 (`nvcr.io/nvidia/isaac-sim:5.1.0`) |

### 重要なハマりどころ（記事 §10 候補）

1. **GRID driver では Isaac Sim 5.1.0 が動かない**（`librtx.scenedb` で必ずクラッシュ）。AWS の Workstation 系記事は GRID driver 推奨が多いが、Isaac Sim では **CUDA Datacenter driver `nvidia-driver-570`** を使う必要あり（`setup-dcv.sh` 適用済）。
2. **`nvidia-xconfig` は CUDA driver パッケージに含まれない**。xorg.conf を手書き（`AllowEmptyInitialConfiguration "True"` を含める）が必要（`setup-dcv.sh` 適用済）。
3. **`./isaac-sim.sh` はデフォルトで Streaming experience を起動**する。Native Desktop GUI には `--entrypoint /isaac-sim/kit/kit` + `/isaac-sim/apps/isaacsim.exp.full.kit` を直接呼ぶ（`setup-isaac.sh` の出力に反映）。
4. **URDF Import 時、ホスト側 `~/work` 配下に書き込み権限が必要**（`sudo chmod -R a+rwX ~/work/`、`setup-isaac.sh` 適用済）。
5. **GPU タイプ切替時は cache クリア必須**（L40S 用 shader cache を A10G で読むと `omni.kit.registry.nucleus` で hang）。
   ```bash
   rm -rf ~/docker/isaac-sim/{kit-cache,ov-cache,gl-cache,compute-cache,logs}
   ```
6. **Physics Inspector** は開いた直後に「Re-Enable authoring」ボタンを押す必要あり。
7. **`xhost +local:docker` は SSH ターミナルでは動かない**（DISPLAY 未設定）。**DCV デスクトップ内ターミナルで実行**するか、SSH なら `export DISPLAY=:0` を先に設定。

### 動作確認マトリックス

| GPU | driver | cache | 結果 |
|--|--|--|--|
| L40S (g6e) | GRID 595 | — | ❌ librtx crash |
| L40S (g6e) | CUDA 570 | 初期 | ✅ 動作 |
| A10G (g5) | CUDA 570 | L40S 用残置 | ❌ nucleus hang |
| **A10G (g5)** | **CUDA 570** | **クリア** | ✅ **完全動作 (推奨)** |

## License

MIT
