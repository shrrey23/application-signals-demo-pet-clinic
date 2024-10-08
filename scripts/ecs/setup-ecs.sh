#!/bin/bash

# Variables
CLUSTER_NAME=$1
REGION=$2
ALB_ENDPOINT=$3
ACCOUNT=$4
SERVICE_NAME="ECS-Front-End"
CONTAINER_NAME="api-gateway-java"
LISTENER_PORT=80
TARGET_PORT=8080
TARGET_GROUP_NAME="pet-clinic-nlb-target-group"
NLB_NAME="pet-clinic-nlb"
TASK_DEF_FILE=task-definition.json
MODIFIED_TASK_DEF_FILE=task-definition-modified.json
IAM_ROLE_NAME="ecsInstanceRole"
IAM_ROLE_INSTANCE_NAME="ecsInstanceRole-profile"
SG_NAME="ecs-security-group"
KEY_NAME="ecs-demo-key-pair"
ECS_ASG_NAME="asg-ecs-pet-clinic-app"
LAUNCH_TEMPLATE_NAME="lt-ecs-pet-clinic-app"
CAPACITY_PROVIDER_NAME="pet-clinic-ecs-capacity-provider"
SECURITY_GROUP="" 

echo "Creating resources..."

# Fetch the latest Amazon Linux 2 AMI ID
IMAGE_ID=$(aws ec2 describe-images \
  --region $REGION \
  --owners amazon \
  --filters "Name=name,Values=amzn2-ami-ecs-kernel-5.10-hvm-2.0.20240909-x86_64-ebs" "Name=state,Values=available" \
  --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
  --output text)

VPC_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text)
echo "EKS Cluster VPC ID: $VPC_ID"

# Fetch the subnets associated with the EKS cluster
SUBNETS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query "join(',', sort_by(Subnets, &AvailabilityZone)[0:1].SubnetId)" --output text)
echo "Subnets associated with EKS Cluster: $SUBNETS"

# List EKS node groups
NODE_GROUPS=$(aws eks list-nodegroups --cluster-name "$CLUSTER_NAME" --query 'nodegroups' --output text)
if [ -z "$NODE_GROUPS" ]; then
  echo "No node groups found for cluster $CLUSTER_NAME"
  exit 1
fi

# Get the Auto Scaling Group (ASG) name from the first node group
ASG_NAME=$(aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NODE_GROUPS" \
  --query 'nodegroup.resources.autoScalingGroups[0].name' --output text  --no-cli-pager --no-cli-auto-prompt < /dev/null)
echo "ASG Name: $ASG_NAME"

# Get EC2 instance IDs from the ASG
EKS_INSTANCE_IDS=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" \
  --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)
echo "Instance IDs: $EKS_INSTANCE_IDS"

# Get security groups attached to the first instance
SECURITY_GROUP=$(aws ec2 describe-security-groups \
--filters "Name=vpc-id,Values=$VPC_ID" \
--query 'SecurityGroups[?contains(GroupName, `ClusterSharedNodeSecurityGroup`)].GroupId' \
--output text)
echo "Security Group: $SECURITY_GROUP"

# Ensure the security group belongs to the same VPC as the subnets
SG_VPC_ID=$(aws ec2 describe-security-groups --group-ids "$SECURITY_GROUP" --query 'SecurityGroups[0].VpcId' --output text)

if [ "$SG_VPC_ID" != "$VPC_ID" ]; then
  echo "Error: Security group $SECURITY_GROUP is not associated with the VPC $VPC_ID"
  exit 1
else
  echo "Security group $SECURITY_GROUP is valid for VPC $VPC_ID"
fi

# Create an IAM role and attach policies
aws iam create-role --role-name $IAM_ROLE_NAME --assume-role-policy-document file://trust-policy.json --no-cli-pager --no-cli-auto-prompt < /dev/null
aws iam attach-role-policy --role-name $IAM_ROLE_NAME --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
aws iam attach-role-policy --role-name $IAM_ROLE_NAME --policy-arn "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
aws iam attach-role-policy --role-name $IAM_ROLE_NAME --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
aws iam attach-role-policy --role-name $IAM_ROLE_NAME --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
aws iam attach-role-policy --role-name $IAM_ROLE_NAME --policy-arn "arn:aws:iam::aws:policy/AmazonSSMReadOnlyAccess"
aws iam attach-role-policy --role-name $IAM_ROLE_NAME --policy-arn "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
aws iam attach-role-policy --role-name $IAM_ROLE_NAME --policy-arn "arn:aws:iam::aws:policy/CloudWatchFullAccess"
aws iam attach-role-policy --role-name $IAM_ROLE_NAME --policy-arn "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
aws iam attach-role-policy --role-name $IAM_ROLE_NAME --policy-arn "arn:aws:iam::aws:policy/AWSXrayWriteOnlyAccess"
aws iam put-role-policy --role-name $IAM_ROLE_NAME --policy-name "ecs-list-write-policy" --policy-document file://ecs-list-write-policy.json
aws iam put-role-policy --role-name $IAM_ROLE_NAME --policy-name "sts-caller-policy" --policy-document file://sts-caller-policy.json
aws iam put-role-policy --role-name $IAM_ROLE_NAME --policy-name "AWSDistroOpenTelemetryPolicy" --policy-document file://aws-distro-policy.json

# Create instance profile
aws iam create-instance-profile --instance-profile-name $IAM_ROLE_INSTANCE_NAME --no-cli-pager --no-cli-auto-prompt < /dev/null
aws iam add-role-to-instance-profile --instance-profile-name $IAM_ROLE_INSTANCE_NAME --role-name $IAM_ROLE_NAME
sleep 30 #wait for the instance profile to be ready

rm -f ${KEY_NAME}.pem
# Create the key pair for SSH
aws ec2 create-key-pair --key-name "${KEY_NAME}" --query 'KeyMaterial' --output text > "${KEY_NAME}.pem" --no-cli-pager --no-cli-auto-prompt < /dev/null
chmod 400  "${KEY_NAME}.pem"

sed "s/\$CLUSTER_NAME/$CLUSTER_NAME/g" user-data.sh > new-user-data.sh

USER_DATA=$(base64 < new-user-data.sh)

cat new-user-data.sh

jq --arg IMAGE_ID "$IMAGE_ID" \
    --arg KEY_NAME "$KEY_NAME" \
    --arg IAM_ROLE_INSTANCE_NAME "$IAM_ROLE_INSTANCE_NAME" \
    --arg ACCOUNT "$ACCOUNT" \
    --arg USER_DATA "$USER_DATA" \
    --arg SECURITY_GROUP "$SECURITY_GROUP" \
    '.ImageId = $IMAGE_ID | 
    .KeyName = $KEY_NAME | 
    .IamInstanceProfile.Arn = "arn:aws:iam::\($ACCOUNT):instance-profile/\($IAM_ROLE_INSTANCE_NAME)" | 
    .UserData = $USER_DATA | 
    .NetworkInterfaces[0].Groups[0] = $SECURITY_GROUP' \
    launch-template.json > output-template.json

aws ec2 create-launch-template \
  --launch-template-name $LAUNCH_TEMPLATE_NAME \
  --version-description "1" \
  --launch-template-data file://output-template.json \
  --no-cli-pager --no-cli-auto-prompt < /dev/null

rm -f "${KEY_NAME}.pem"
rm -f new-user-data.sh
rm -f output-template.json

# Create Auto Scaling Group
echo "Creating Auto Scaling Group..."
aws autoscaling create-auto-scaling-group \
  --auto-scaling-group-name $ECS_ASG_NAME \
  --launch-template "LaunchTemplateName=$LAUNCH_TEMPLATE_NAME,Version=1" \
  --min-size 1 \
  --max-size 1 \
  --desired-capacity 1 \
  --vpc-zone-identifier "$SUBNETS" \
  --new-instances-protected-from-scale-in \
  --no-cli-pager --no-cli-auto-prompt < /dev/null

echo "Auto Scaling Group created."

# Wait for the ASG to launch EC2 instances
instance_id=$(aws autoscaling describe-auto-scaling-instances --query "AutoScalingInstances[?AutoScalingGroupName=='$ECS_ASG_NAME'].InstanceId" --output text)
while [ -z "$instance_id" ]; do
  sleep 5
  instance_id=$(aws autoscaling describe-auto-scaling-instances --query "AutoScalingInstances[?AutoScalingGroupName=='$ECS_ASG_NAME'].InstanceId" --output text)
done

# Tag the instance
aws ec2 create-tags --resources $instance_id --tags Key=Name,Value=$SERVICE_NAME

# Wait for the instance to be in the 'running' state
echo "Checking instance: $instance_id"
aws ec2 wait instance-status-ok --instance-ids $instance_id
echo "Instance $instance_id is running."

# Create Network Load Balancer
echo "Creating Network Load Balancer..."
NLB_ARN=$(aws elbv2 create-load-balancer \
  --name $NLB_NAME \
  --type network \
  --subnets $SUBNETS \
  --security-groups $SECURITY_GROUP \
  --query "LoadBalancers[0].LoadBalancerArn" \
  --output text \
  --no-cli-pager --no-cli-auto-prompt < /dev/null)

echo "NLB ARN: $NLB_ARN"

# Create target group
echo "Creating target group..."
TARGET_GROUP_ARN=$(aws elbv2 create-target-group \
  --name $TARGET_GROUP_NAME \
  --protocol TCP \
  --port $TARGET_PORT \
  --vpc-id $VPC_ID \
  --target-type ip \
  --query "TargetGroups[0].TargetGroupArn" \
  --output text \
  --no-cli-pager --no-cli-auto-prompt < /dev/null)

INSTANCE_IP=$(aws ec2 describe-instances --instance-ids $instance_id --query "Reservations[].Instances[].PrivateIpAddress" --output text)

# Register instance with target group
echo "Registering instance with target group..."
aws elbv2 register-targets --target-group-arn $TARGET_GROUP_ARN --targets Id=$INSTANCE_IP,Port=$TARGET_PORT

# Create listener
echo "Creating listener..."
aws elbv2 create-listener \
--load-balancer-arn $NLB_ARN \
--protocol TCP \
--port 80 \
--default-actions Type=forward,TargetGroupArn=$TARGET_GROUP_ARN \
--no-cli-pager --no-cli-auto-prompt < /dev/null

# Register task definition with ECS
echo "Registering task definition..."

jq --arg account "$ACCOUNT" --arg region "$REGION" --arg config "http://$ALB_ENDPOINT" --arg role $IAM_ROLE_NAME \
'.containerDefinitions[] |= (
    .image |= gsub("<ACCOUNT>"; $account) |
    .image |= gsub("<REGION>"; $region) |
    .environment[]? |= (.value |= gsub("<CONFIG_URL>"; $config))
  ) |
  .taskRoleArn |= gsub("<ACCOUNT>"; $account) |
  .taskRoleArn |= gsub("<ROLE-ARN>"; $role) |
  .executionRoleArn |= gsub("<ACCOUNT>"; $account) |
  .executionRoleArn |= gsub("<ROLE-ARN>"; $role)' \
 "$TASK_DEF_FILE" > "$MODIFIED_TASK_DEF_FILE"


TASK_DEFINITION_ARN=$(aws ecs register-task-definition --cli-input-json file://$MODIFIED_TASK_DEF_FILE \
                      --query "taskDefinition.taskDefinitionArn" --output text --no-cli-pager --no-cli-auto-prompt < /dev/null)

rm -f $MODIFIED_TASK_DEF_FILE

echo "Task Definition ARN: $TASK_DEFINITION_ARN"

# Create Capacity Provider using ASG
echo "Creating Capacity Provider for ECS cluster..."

# Attach ASG to the ECS cluster via a Capacity Provider
aws ecs create-capacity-provider \
  --name $CAPACITY_PROVIDER_NAME \
  --auto-scaling-group-provider "{
    \"autoScalingGroupArn\": \"$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $ECS_ASG_NAME --query 'AutoScalingGroups[0].AutoScalingGroupARN' --output text)\",
    \"managedScaling\": {
      \"status\": \"ENABLED\",
      \"targetCapacity\": 100
    },
    \"managedTerminationProtection\": \"ENABLED\"
  }" \
  --no-cli-pager --no-cli-auto-prompt < /dev/null


# Create ECS cluster
echo "Creating ECS cluster..."
aws ecs create-cluster \
  --cluster-name $CLUSTER_NAME \
  --capacity-providers $CAPACITY_PROVIDER_NAME \
  --default-capacity-provider-strategy "capacityProvider=$CAPACITY_PROVIDER_NAME,weight=1,base=1" \
  --no-cli-pager --no-cli-auto-prompt < /dev/null

# Wait for the cluster to be ready
while true; do
  STATUS=$(aws ecs describe-clusters --clusters $CLUSTER_NAME --query "clusters[0].status" --output text)
  if [ "$STATUS" == "ACTIVE" ]; then
    echo "Cluster $CLUSTER_NAME is active."
    break
  else
    echo "Waiting for cluster $CLUSTER_NAME to become active..."
    sleep 10
  fi
done

echo "Configuring ecs-cwagent parameter..."
aws ssm put-parameter \
    --name "ecs-cwagent" \
    --type String \
    --value '{
      "traces": {
        "traces_collected": {
          "application_signals": {}
        }
      },
      "logs": {
        "metrics_collected": {
          "application_signals": {}
        }
      }
    }' \
  --overwrite \
  --no-cli-pager --no-cli-auto-prompt < /dev/null

# # Create ECS service with the Capacity Provider
echo "Creating ECS service..."
aws ecs create-service \
  --cluster $CLUSTER_NAME \
  --service-name $SERVICE_NAME \
  --task-definition $TASK_DEFINITION_ARN \
  --desired-count 1 \
  --scheduling-strategy "REPLICA" \
  --deployment-controller type=ECS \
  --launch-type "EC2" \
  --enable-execute-command \
  --no-cli-pager --no-cli-auto-prompt < /dev/null

aws ecs update-cluster-settings --cluster $CLUSTER_NAME --settings name=containerInsights,value=enabled 

check_target_group_health() {
    aws elbv2 describe-target-health --target-group-arn $TARGET_GROUP_ARN \
    --query 'TargetHealthDescriptions[*].TargetHealth.State' --output text
}

while true; do
    HEALTH_STATUS=$(check_target_group_health)
    
    echo "Current target group health status: $HEALTH_STATUS"

    # Check if all targets are healthy
    if [[ "$HEALTH_STATUS" == *"healthy"* ]]; then
        echo "All targets are healthy. NLB is ready."
        break
    else
        echo "Waiting for NLB to start listening to the target group..."
        sleep 10  # Wait for 10 seconds before checking again
    fi
done

SECURITY_GROUP_IDS=$(aws ec2 describe-security-groups --filters Name=vpc-id,Values=$VPC_ID --query "SecurityGroups[*].GroupId" --output text)
echo "Attaching security groups to NLB: $NLB_ARN..."
aws elbv2 set-security-groups --load-balancer-arn $NLB_ARN --security-groups $SECURITY_GROUP_IDS --no-cli-pager --no-cli-auto-prompt < /dev/null

echo $PWD
ls
./refresh_dashboard.sh $CLUSTER_NAME $REGION

echo "ECS Cluster, ASG, and Service setup complete!"


