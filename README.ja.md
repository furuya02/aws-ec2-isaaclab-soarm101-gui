# aws-ec2-isaaclab-soarm101-gui

AWS EC2 + NICE DCV で Isaac Sim / Isaac Lab の GUI を起動し、SO-ARM101 を手動操作するためのインフラ一式（AWS CDK / TypeScript）。

---

## 重要: コスト警告

このスタックは **GPU 付き EC2 を扱うため放置すると高額**になります。必ず最後に [削除手順](#7-削除完全) を実行してください。

| 項目 | 単価 | 24h 放置 |
|--|--|--|
| EC2 `g5.xlarge` (A10G 24GB) | 約 $1.30/h ≒ 約 195 円/h | 約 $31 ≒ **約 4,700 円/日** |
| EC2 `t3.medium`（普段） | 約 $0.05/h ≒ 約 7.5 円/h | 約 $1.2 ≒ 約 180 円/日 |
| EBS gp3 50 GB | $0.10/GB/月 | — |
| Elastic IP（停止中も課金） | $0.005/h | 約 18 円/日 |

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
- EC2 Instance（初期 `t3.medium`、Ubuntu 22.04 LTS、EBS gp3 50 GB、EIP 付与）
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

デプロイ完了後、Outputs に以下が表示されます:

- `InstanceId`
- `PublicIp`（Elastic IP）
- `SshCommand`
- `SsmStartCommand`
- `DcvUrl`（DCV セットアップ後にブラウザで開く URL）

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
| `scripts/connect.sh` | ローカル PC | EIP を引いて SSH 接続 |
| `scripts/setup-docker.sh` | EC2 (t3 で OK) | Docker + NVIDIA Container Toolkit |
| `scripts/switch-to-g5.sh` | ローカル PC | t3.medium → g5.xlarge |
| `scripts/setup-dcv.sh` | EC2 (g5) | NVIDIA GRID Driver + Amazon DCV Server |
| `scripts/setup-isaac.sh` | EC2 (g5) | NGC login + Isaac Sim pull + isaac_so_arm101 clone |
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
9. 表示された `docker run` で Isaac Sim 起動 → URDF Import → Physics Inspector で操作
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
# EC2 / EIP / EBS / SG の残留がないこと
aws ec2 describe-instances --filters Name=tag:Name,Values=aws-ec2-isaaclab-soarm101-gui-instance
aws ec2 describe-addresses --filters Name=tag:Name,Values=aws-ec2-isaaclab-soarm101-gui-eip
aws ec2 describe-volumes --filters Name=tag:Name,Values=aws-ec2-isaaclab-soarm101-gui-instance
```

翌日 Cost Explorer で当該リソースの課金が 0 円になっていることも確認してください。

## 実機検証メモ（2026/05/18）

本リポジトリの `cdk/` と `scripts/` は初期スキャフォールド版です。実機検証で以下の **動作する設定** が判明したものの、まだ `scripts/` に反映されていません。次回更新で取り込み予定です。

### 動作確認済構成

| 項目 | 値 |
|--|--|
| インスタンス | **g6e.xlarge (L40S)**（g5/g6 = A10G/L4 は未検証） |
| AMI | Ubuntu 22.04.5 LTS HVM |
| NVIDIA Driver | **CUDA Datacenter driver 570** (`nvidia-driver-570`) |
| Amazon DCV | 2025.0（Ubuntu 22.04 x86_64） |
| Isaac Sim | 5.1.0-rc.19 (`nvcr.io/nvidia/isaac-sim:5.1.0`) |

### 重要なハマりどころと対処

1. **GRID driver では Isaac Sim 5.1.0 が動かない**（`librtx.scenedb` で必ずクラッシュ）。`scripts/setup-dcv.sh` は GRID driver をインストールしているが、**CUDA Datacenter driver に置き換える必要あり**。
2. **`nvidia-xconfig` は CUDA driver パッケージに含まれない**。xorg.conf を手書き（`AllowEmptyInitialConfiguration "True"` を含める）。
3. **`./isaac-sim.sh` はデフォルトで Streaming experience を起動**する。Native GUI には `./kit/kit /isaac-sim/apps/isaacsim.exp.full.kit` を直接呼ぶ必要あり（`--experience` 引数は内部で無視される）。
4. **URDF Import 時、ホスト側 `~/work` 配下に書き込み権限が必要**（`sudo chmod -R a+rwX ~/work/`）。コンテナ内 root が USD 変換ファイルを書き出すため。
5. **Physics Inspector** は開いた直後に `[No selection]` + 「Re-Enable authoring」ボタンが出る。これを押して articulation を再パースする必要あり。

### 動作する Isaac Sim 起動コマンド（DCV デスクトップ内ターミナルで）

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

### 次回確認予定

- g5.xlarge (A10G) でも CUDA driver 570 で同様に動くか
- 動けば scripts/ を実機準拠に修正（GRID → CUDA driver、kit 直接呼び出し、chmod、apt source 追加 等）

## License

MIT
