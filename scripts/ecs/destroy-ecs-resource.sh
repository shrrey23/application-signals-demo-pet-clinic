#!/bin/bash

# Variables
CLUSTER_NAME=$1
REGION=$2
ACCOUNT=$3
SERVICE_NAME="ECS-Front-End"
FAMILY_NAME="pet-clinic-frontend-java-task"
IAM_ROLE_NAME="ecsInstanceRole"
IAM_ROLE_INSTANCE_NAME="ecsInstanceRole-profile"
SG_NAME="ecs-security-group"
KEY_NAME="ecs-demo-key-pair"
NLB_NAME="pet-clinic-nlb"
TARGET_GROUP_NAME="pet-clinic-nlb-target-group"
ASG_NAME="asg-ecs-pet-clinic-app"
LAUNCH_TEMPLATE_NAME="lt-ecs-pet-clinic-app"
CAPACITY_PROVIDER_NAME="pet-clinic-ecs-capacity-provider"

# Step 1: Update the service to set desired count to 0
echo "Deleting ECS Service..."
aws ecs update-service --cluster $CLUSTER_NAME --service $SERVICE_NAME --desired-count 0 --no-cli-pager --no-cli-auto-prompt < /dev/null

aws ecs update-cluster --cluster $CLUSTER_NAME --capacity-providers []

# Step 2: Wait for the service tasks to stop
echo "Waiting for the service tasks to stop..."
while true; do
    RUNNING_TASKS=$(aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME --query "services[0].runningCount" --output text)
    if [ "$RUNNING_TASKS" -eq 0 ]; then
        echo "All tasks have stopped."
        break
    fi
    echo "Waiting... Current running tasks: $RUNNING_TASKS"
    sleep 5  # Wait for 5 seconds before checking again
done

# Step 3: Delete the ECS service
aws ecs delete-service --cluster $CLUSTER_NAME --service $SERVICE_NAME --no-cli-auto-prompt --no-cli-pager --force < /dev/null

# Step 4: Set container instances to DRAINING
echo "Setting container instances to DRAINING..."
INSTANCE_ARNs=$(aws ecs list-container-instances --cluster $CLUSTER_NAME --query "containerInstanceArns[]" --output text --no-cli-pager)

for INSTANCE_ARN in $INSTANCE_ARNs; do
    aws ecs update-container-instances-state --cluster $CLUSTER_NAME --container-instances $INSTANCE_ARN --status DRAINING --no-cli-pager
done

# Step 6: Delete capacity provider if needed
aws ecs delete-capacity-provider --capacity-provider $CAPACITY_PROVIDER_NAME --no-cli-auto-prompt --no-cli-pager < /dev/null

echo "ECS Service and Capacity Provider deletion complete."

# Delete ECS Cluster
echo "Deleting ECS Cluster..."
aws ecs delete-cluster --cluster $CLUSTER_NAME --no-cli-auto-prompt --no-cli-pager < /dev/null

# Delete Auto Scaling Group (ASG)
echo "Deleting Auto Scaling Group..."
aws autoscaling delete-auto-scaling-group --auto-scaling-group-name $ASG_NAME --force-delete --no-cli-auto-prompt --no-cli-pager < /dev/null

# Delete Launch Template
echo "Deleting Launch Template..."
aws ec2 delete-launch-template --launch-template-name $LAUNCH_TEMPLATE_NAME --no-cli-auto-prompt --no-cli-pager < /dev/null

TARGET_GROUP_ARN=$(aws elbv2 describe-target-groups --names $TARGET_GROUP_NAME --query "TargetGroups[0].TargetGroupArn" --output text) 

echo "Listing registered targets in the target group..."
TARGETS=$(aws elbv2 describe-target-health --target-group-arn $TARGET_GROUP_ARN \
    --query 'TargetHealthDescriptions[*].Target.Id' --output text)

if [ -z "$TARGETS" ]; then
    echo "No targets found in the target group."
else
    for TARGET in $TARGETS; do
        aws elbv2 deregister-targets --target-group-arn $TARGET_GROUP_ARN --targets Id=$TARGET
        echo "Deregistered target: $TARGET"
    done
    sleep 120
fi

# Delete Network Load Balancer (NLB)
echo "Deleting NLB..."
NLB_ARN=$(aws elbv2 describe-load-balancers --names $NLB_NAME --query "LoadBalancers[0].LoadBalancerArn" --output text)
aws elbv2 delete-load-balancer --load-balancer-arn $NLB_ARN

# Delete Target Group
echo "Deleting Target Group..."
aws elbv2 delete-target-group --target-group-arn $TARGET_GROUP_ARN --no-cli-pager --no-cli-auto-prompt < /dev/null

# Delete key pair
echo "Deleting Key Pair..."
aws ec2 delete-key-pair --key-name $KEY_NAME --no-cli-auto-prompt --no-cli-pager < /dev/null
rm -f "${KEY_NAME}.pem"

rm -f master_password.txt

# Delete IAM Role and Instance Profile
echo "Deleting IAM Roles..."
aws iam remove-role-from-instance-profile --instance-profile-name $IAM_ROLE_INSTANCE_NAME --role-name $IAM_ROLE_NAME --no-cli-auto-prompt < /dev/null
aws iam delete-instance-profile --instance-profile-name $IAM_ROLE_INSTANCE_NAME --no-cli-auto-prompt < /dev/null
aws iam detach-role-policy --role-name $IAM_ROLE_NAME --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
aws iam detach-role-policy --role-name $IAM_ROLE_NAME --policy-arn "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
aws iam detach-role-policy --role-name $IAM_ROLE_NAME --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
aws iam detach-role-policy --role-name $IAM_ROLE_NAME --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
aws iam detach-role-policy --role-name $IAM_ROLE_NAME --policy-arn "arn:aws:iam::aws:policy/AmazonSSMReadOnlyAccess"
aws iam detach-role-policy --role-name $IAM_ROLE_NAME --policy-arn "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
aws iam detach-role-policy --role-name $IAM_ROLE_NAME --policy-arn "arn:aws:iam::aws:policy/CloudWatchFullAccess"
aws iam detach-role-policy --role-name $IAM_ROLE_NAME --policy-arn "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
aws iam detach-role-policy --role-name $IAM_ROLE_NAME --policy-arn "arn:aws:iam::aws:policy/AWSXrayWriteOnlyAccess"
aws iam delete-role-policy --role-name $IAM_ROLE_NAME --policy-name "ecs-list-write-policy"
aws iam delete-role-policy --role-name $IAM_ROLE_NAME --policy-name "sts-caller-policy"
aws iam delete-role-policy --role-name $IAM_ROLE_NAME --policy-name "AWSDistroOpenTelemetryPolicy"
aws iam delete-role --role-name $IAM_ROLE_NAME --no-cli-auto-prompt < /dev/null

aws ecs delete-cluster --cluster $CLUSTER_NAME --no-cli-auto-prompt --no-cli-pager < /dev/null

echo "All ECS-related resources deleted successfully!"
