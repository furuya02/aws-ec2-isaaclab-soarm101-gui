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

    // No context required. Access is via SSM Session Manager (port-forward localhost:8443 -> EC2:8443).
    // No SSH key pair, no inbound CIDR. Inbound is fully closed.

    const vpc = new ec2.Vpc(this, 'Vpc', {
      vpcName: `${PROJECT}-vpc`,
      ipAddresses: ec2.IpAddresses.cidr('10.0.0.0/16'),
      availabilityZones: [TARGET_AZ],
      natGateways: 0,
      subnetConfiguration: [
        { name: 'public', subnetType: ec2.SubnetType.PUBLIC, cidrMask: 24 },
      ],
    });

    // Security Group: NO inbound rules. All access goes through SSM Session Manager.
    // - SSM agent on the instance dials out to AWS API over the public IP (egress 443).
    // - DCV browser session is tunneled via `aws ssm start-session ... AWS-StartPortForwardingSession`
    //   so we never need to open 22 or 8443 on the SG.
    const sg = new ec2.SecurityGroup(this, 'SecurityGroup', {
      vpc,
      securityGroupName: `${PROJECT}-sg`,
      description: 'SSM-only access (inbound fully closed) for Isaac Sim host',
      allowAllOutbound: true,
    });

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

    // Outputs are IP-independent. Both commands work regardless of the current Public IP.
    new cdk.CfnOutput(this, 'InstanceId', {
      value: instance.instanceId,
      description: 'EC2 Instance ID (stable across stop/start)',
    });
    new cdk.CfnOutput(this, 'SsmStartCommand', {
      value: `aws ssm start-session --target ${instance.instanceId} --region ${this.region}`,
      description: 'Interactive shell via SSM Session Manager (no SSH key, no inbound port)',
    });
    new cdk.CfnOutput(this, 'DcvPortForwardCommand', {
      value:
        `aws ssm start-session --target ${instance.instanceId} --region ${this.region}` +
        ` --document-name AWS-StartPortForwardingSession` +
        ` --parameters '{"portNumber":["8443"],"localPortNumber":["8443"]}'`,
      description: 'Port-forward localhost:8443 -> EC2:8443 for Amazon DCV browser access',
    });
  }
}
