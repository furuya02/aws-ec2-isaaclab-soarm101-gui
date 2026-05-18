import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as cloudwatch from 'aws-cdk-lib/aws-cloudwatch';
import * as cw_actions from 'aws-cdk-lib/aws-cloudwatch-actions';

const PROJECT = 'aws-ec2-isaaclab-soarm101-gui';
const TARGET_AZ = 'ap-northeast-1a';
const UBUNTU_22_04_SSM_PARAM =
  '/aws/service/canonical/ubuntu/server/22.04/stable/current/amd64/hvm/ebs-gp2/ami-id';

export class AwsEc2IsaaclabSoarm101GuiStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    const keypairName: string | undefined = this.node.tryGetContext('keypair_name');
    const allowedCidr: string | undefined = this.node.tryGetContext('allowed_cidr');
    if (!keypairName) {
      throw new Error(
        'Missing context: keypair_name. Pass via `pnpm cdk deploy -c keypair_name=<existing key pair name>`',
      );
    }
    if (!allowedCidr) {
      throw new Error(
        'Missing context: allowed_cidr. Pass via `pnpm cdk deploy -c allowed_cidr=<your global IP>/32`',
      );
    }

    const vpc = new ec2.Vpc(this, 'Vpc', {
      vpcName: `${PROJECT}-vpc`,
      ipAddresses: ec2.IpAddresses.cidr('10.0.0.0/16'),
      availabilityZones: [TARGET_AZ],
      natGateways: 0,
      subnetConfiguration: [
        { name: 'public', subnetType: ec2.SubnetType.PUBLIC, cidrMask: 24 },
      ],
    });

    const sg = new ec2.SecurityGroup(this, 'SecurityGroup', {
      vpc,
      securityGroupName: `${PROJECT}-sg`,
      description: 'SSH and NICE DCV access for Isaac Sim host',
      allowAllOutbound: true,
    });
    sg.addIngressRule(ec2.Peer.ipv4(allowedCidr), ec2.Port.tcp(22), 'SSH from allowed CIDR');
    sg.addIngressRule(ec2.Peer.ipv4(allowedCidr), ec2.Port.tcp(8443), 'NICE DCV TCP from allowed CIDR');
    sg.addIngressRule(ec2.Peer.ipv4(allowedCidr), ec2.Port.udp(8443), 'NICE DCV UDP/QUIC from allowed CIDR');

    const role = new iam.Role(this, 'InstanceRole', {
      roleName: `${PROJECT}-ec2-role`,
      assumedBy: new iam.ServicePrincipal('ec2.amazonaws.com'),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonSSMManagedInstanceCore'),
      ],
    });
    role.addToPolicy(
      new iam.PolicyStatement({
        sid: 'DcvLicenseAndNvidiaDriverRead',
        actions: ['s3:GetObject', 's3:ListBucket'],
        resources: [
          `arn:aws:s3:::dcv-license.${this.region}`,
          `arn:aws:s3:::dcv-license.${this.region}/*`,
          'arn:aws:s3:::ec2-linux-nvidia-drivers',
          'arn:aws:s3:::ec2-linux-nvidia-drivers/*',
        ],
      }),
    );

    const machineImage = ec2.MachineImage.fromSsmParameter(UBUNTU_22_04_SSM_PARAM, {
      os: ec2.OperatingSystemType.LINUX,
    });

    const instance = new ec2.Instance(this, 'Instance', {
      vpc,
      vpcSubnets: { subnetType: ec2.SubnetType.PUBLIC },
      availabilityZone: TARGET_AZ,
      instanceType: ec2.InstanceType.of(ec2.InstanceClass.T3, ec2.InstanceSize.MEDIUM),
      machineImage,
      keyPair: ec2.KeyPair.fromKeyPairName(this, 'KeyPair', keypairName),
      securityGroup: sg,
      role,
      blockDevices: [
        {
          deviceName: '/dev/sda1',
          // 35 GB: Isaac Sim 5.1.0 container (22.9 GB) + OS / NVIDIA driver / Ubuntu Desktop / DCV (~6 GB) + headroom (~6 GB).
          // gp3 is online-expandable, so start small and grow with `modify-volume` + `resize2fs` if needed.
          volume: ec2.BlockDeviceVolume.ebs(35, {
            volumeType: ec2.EbsDeviceVolumeType.GP3,
            deleteOnTermination: true,
            encrypted: true,
          }),
        },
      ],
    });
    cdk.Tags.of(instance).add('Name', `${PROJECT}-instance`);

    // Note: Elastic IP is intentionally NOT created.
    // - Public IPv4 charge is the same whether EIP or auto-assigned ($0.005/h while attached).
    // - But auto-assigned Public IP is RELEASED on stop, so cost while stopped becomes $0.
    // - Trade-off: Public IP changes on every stop/start. connect.sh queries by Name tag, so it
    //   still works, but the DCV browser URL must be re-checked after each start.

    const idleAlarm = new cloudwatch.Alarm(this, 'IdleStopAlarm', {
      alarmName: `${PROJECT}-idle-stop`,
      alarmDescription:
        'Auto-stop EC2 when CPUUtilization < 2% for 30 minutes (forgotten shutdown protection)',
      metric: new cloudwatch.Metric({
        namespace: 'AWS/EC2',
        metricName: 'CPUUtilization',
        dimensionsMap: { InstanceId: instance.instanceId },
        period: cdk.Duration.minutes(5),
        statistic: 'Average',
      }),
      threshold: 2,
      comparisonOperator: cloudwatch.ComparisonOperator.LESS_THAN_THRESHOLD,
      evaluationPeriods: 6,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
    });
    idleAlarm.addAlarmAction(new cw_actions.Ec2Action(cw_actions.Ec2InstanceAction.STOP));

    // Outputs are intentionally limited to IP-independent values.
    // Public IP changes on every stop/start (no EIP), so SshCommand / DcvUrl that embed
    // a fixed IP at deploy time would be misleading. Use these instead:
    //   - SSH:     ./scripts/connect.sh   (queries Public IP by Name tag at run time)
    //   - DCV URL: get-public-ip via describe-instances, then https://<ip>:8443
    //   - SSM:     aws ssm start-session ... (IP-independent, works even while no public IP)
    new cdk.CfnOutput(this, 'InstanceId', {
      value: instance.instanceId,
      description: 'EC2 Instance ID (stable across stop/start)',
    });
    new cdk.CfnOutput(this, 'SsmStartCommand', {
      value: `aws ssm start-session --target ${instance.instanceId} --region ${this.region}`,
      description: 'SSM Session Manager command (no pem, no IP dependency)',
    });
  }
}
