#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import { AwsEc2IsaaclabSoarm101GuiStack } from '../lib/aws-ec2-isaaclab-soarm101-gui-stack';

const app = new cdk.App();

new AwsEc2IsaaclabSoarm101GuiStack(app, 'AwsEc2IsaaclabSoarm101GuiStack', {
  stackName: 'aws-ec2-isaaclab-soarm101-gui',
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: process.env.CDK_DEFAULT_REGION ?? 'ap-northeast-1',
  },
  description: 'EC2 + Amazon DCV + Isaac Sim GUI host via SSM port-forward (t3.medium <-> g5.xlarge switchable, idle Auto-Stop)',
});
