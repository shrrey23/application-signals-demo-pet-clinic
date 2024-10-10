#!/bin/bash
# set -x

# change the directory to the script location so that the relative path can work
cd "$(dirname "$0")"

# check aws cli version to make sure it's recent enough
# Get the AWS CLI version
version=$(aws --version 2>&1 | cut -d/ -f2 | cut -d' ' -f1)

# Use sort -V (version sort) to compare the version numbers
min_version="2.13.0"
if [[ $(echo -e "$min_version\n$version" | sort -V | head -n1) == "$version" && "$min_version" != "$version" ]]; then
    echo "Your AWS CLI version is lower than 2.13.0. Please upgrade your AWS CLI version: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    exit 1
fi

# Continue with the rest of your script here
echo "AWS CLI version is acceptable, continuing..."

# Set variables with provided arguments or default values
CLUSTER_NAME=$1
REGION=$2
NAMESPACE=${3:-default}

ACCOUNT=$(aws sts get-caller-identity | jq -r '.Account')
DASHBOARD_NAME="ECS_EKS_Dashboard"
SNS_TOPIC_NAME="Default_CloudWatch_Alarms_Topic"
DASHBOARD_NAME="Simba-Pet-Clinic-Demo-Dashboard"
EMAIL="demo123@amazon.com"
ECS_INSTANCE_IDS=""
EKS_INSTANCE_IDS=""
ECS_EBS_VOLUME_IDS=""
EKS_EBS_VOLUME_IDS=""

check_if_step_failed_and_exit() {
  if [ $? -ne 0 ]; then
    echo $1
    exit 1
  fi
}

# Function to get EC2 instance IDs from an ECS Cluster
get_ecs_instance_ids() {
  ECS_INSTANCE_IDS=$(aws ecs list-container-instances --cluster "$CLUSTER_NAME" --region "$REGION" --query "containerInstanceArns[]" --output text)
  if [ -n "$ECS_INSTANCE_IDS" ]; then
    ECS_INSTANCE_IDS=$(aws ecs describe-container-instances --cluster "$CLUSTER_NAME" --container-instances $ECS_INSTANCE_IDS --region "$REGION" --query "containerInstances[*].ec2InstanceId" --output text)
  fi
  echo "$ECS_INSTANCE_IDS"
}

# Function to get EC2 instance IDs from an EKS Cluster
get_eks_instance_ids() {
  EKS_INSTANCE_IDS=$(aws ec2 describe-instances \
    --filters "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
    --region "$REGION" \
    --query "Reservations[*].Instances[*].InstanceId" \
    --output text)
  echo "$EKS_INSTANCE_IDS"
}

# Function to get EBS volumes attached to the EC2 instances
get_ebs_volumes() {
  INSTANCE_IDS=("$@")
  if [ -z "$INSTANCE_IDS" ]; then
    echo "No instances found."
    exit 1
  fi

  VOLUME_IDS=""
  for INSTANCE_ID in "${INSTANCE_IDS[@]}"; do
    INSTANCE_VOLUME_IDS=$(aws ec2 describe-volumes --filters "Name=attachment.instance-id,Values=${INSTANCE_ID}" --region "$REGION" --query "Volumes[*].VolumeId" --output text)
    VOLUME_IDS+="$INSTANCE_VOLUME_IDS "
  done
  echo "$VOLUME_IDS"
}

append_latency_and_request_metric_once() {
    # Append the Latency metric only once
    METRICS_ARRAY=$(echo "$METRICS_ARRAY" | jq --arg region "$REGION" '. + [
        {
            "type": "metric",
            "x": 0,
            "y": 0,
            "width": 12,
            "height": 8,
            "properties": {
                "metrics": [
                    [ { "expression": "SEARCH(\"{ApplicationSignals,Environment,Service} MetricName=\\\"Latency\\\"\", \"Average\", 300)", "id": "e1", "period": 300, "region": $region, "label": "Max : ${MAX}, Avg : ${AVG}", "visible": false } ],
                    [ { "expression": "SORT(e1, AVG, DESC, 6)", "label": "Max : ${MAX}, Avg : ${AVG}", "id": "e2" } ]
                ],
                "liveData": false,
                "period": 300,
                "yAxis": {
                    "left": {
                        "label": "Milliseconds",
                        "showUnits": false
                    }
                },
                "title": "Latency by service : SEARCH({ApplicationSignals,Environment,Service} MetricName=Latency, Average, 300)",
                "region": $region,
                "view": "timeSeries",
                "stacked": false,
                "stat": "p99"
            }
        }, {
            "type": "metric",
            "x": 12,
            "y": 0,
            "width": 12,
            "height": 8,
            "properties": {
                "metrics": [
                    [ { "expression": "SEARCH(\"{ApplicationSignals,Environment,Service} MetricName=\\\"Latency\\\"\", \"Average\", 300)", "id": "e1", "period": 300, "region": $region, "label": "Max : ${MAX}, Avg : ${AVG}", "visible": false } ],
                    [ { "expression": "SORT(e1, AVG, DESC, 6)", "label": "Max : ${MAX}, Avg : ${AVG}", "id": "e2" } ]
                ],
                "liveData": false,
                "period": 300,
                "yAxis": {
                    "left": {
                        "label": "Count",
                        "showUnits": false
                    }
                },
                "title": "Requests by service and top operations : SEARCH({ApplicationSignals,Environment,Service} MetricName=Latency, Average, 300)",
                "region": $region,
                "view": "timeSeries",
                "stacked": false,
                "stat": "SampleCount"
            }
        }
    ]')
}

# Function to append a single CPU utilization metric for a cluster
append_cpu_metric() {
    local cluster_type=$1
    local cluster=$2

    METRICS_ARRAY=$(echo "$METRICS_ARRAY" | jq --arg cluster "$cluster" --arg type "$cluster_type" --argjson x_pos $x_position --argjson y_pos $y_position \
        '. + [
            {
                "type": "metric",
                "x": $x_pos,
                "y": $y_pos,
                "width": 8,
                "height": 6,
                "properties": {
                    "metrics": [
                        [ "AWS/EC2", "CPUUtilization", "InstanceId", $cluster,
                        { "label": "[avg: ${AVG}] \($cluster)", "region": "'"$REGION"'" } ]
                    ],
                    "title": "\($type) CPU Utilization: \($cluster)",
                    "period": 300,
                    "stat": "Average",
                    "view": "timeSeries",
                    "region": "'"$REGION"'"
                }
            }
        ]')
}

# Function to append a single EBS volume metric
append_ebs_metric() {
    local cluster_type=$1
    local volume=$2

    METRICS_ARRAY=$(echo "$METRICS_ARRAY" | jq --arg volume "$volume" --arg type "$cluster_type" --argjson x_pos $x_position --argjson y_pos $y_position \
        '. + [
            {
                "type": "metric",
                "x": $x_pos,
                "y": $y_pos,
                "width": 8,
                "height": 6,
                "properties": {
                    "yAxis": {
                        "left": {
                            "min": 0
                        }
                    },
                    "metrics": [
                        [ "AWS/EBS", "VolumeWriteBytes", "VolumeId", $volume, 
                        { "label": "[avg: ${AVG}]  \($volume)", "region": "'"$REGION"'" } ]
                    ],
                    "title": "\($type) Write throughput(Bytes/s) : \($volume)",
                    "period": 300,
                    "stat": "Sum",
                    "view": "timeSeries",
                    "region": "'"$REGION"'"
                }
            }
        ]')
}

append_log_metric() {
    local log_group=$1
    local region=$2

    METRICS_ARRAY=$(echo "$METRICS_ARRAY" | jq --arg log_group "'$log_group'" --arg region "$region" --argjson x_pos $x_position --argjson y_pos $y_position \
    '. + [
        {
            "height": 8,
            "width": 12,
            "y": $y_pos,
            "x": $x_pos,
            "type": "log",
            "properties": {
                "query": "SOURCE \($log_group) | fields @timestamp, @message, @logStream, @log | sort @timestamp desc | limit 20",
                "region": $region,
                "title": "Log group: \($log_group)",
                "view": "table"
            }
        }
    ]')
    x_position=$((x_position + 12))
}

delete_existing_alarm() {
  ALARM_NAME=$1
  
  echo "Checking if CloudWatch alarm $ALARM_NAME exists..."
  
  ALARM_EXISTS=$(aws cloudwatch describe-alarms --alarm-names "$ALARM_NAME" --query "MetricAlarms[0].AlarmName" --output text)

  if [ "$ALARM_EXISTS" != "None" ]; then
    echo "Alarm $ALARM_NAME exists. Deleting..."
    aws cloudwatch delete-alarms --alarm-names "$ALARM_NAME"
    echo "Deleted alarm $ALARM_NAME."
  else
    echo "No existing alarm named $ALARM_NAME found."
  fi
}

create_asg_alarm() {
  INSTANCE_ID=$1
  TYPE=$2

  echo "Creating alarm for instance $INSTANCE_ID of type $TYPE"

  delete_existing_alarm "$TYPE : High CPU Utilization Alarm"

  # Check if SNS topic exists
  SNS_TOPIC_ARN=$(aws sns list-topics --query "Topics[?ends_with(TopicArn, ':$SNS_TOPIC_NAME')].TopicArn" --output text)

  # If SNS topic does not exist, create it
  if [ -z "$SNS_TOPIC_ARN" ]; then
    echo "SNS topic $SNS_TOPIC_NAME does not exist. Creating it now..."
    SNS_TOPIC_ARN=$(aws sns create-topic --name "$SNS_TOPIC_NAME" --query 'TopicArn' --output text)
    echo "Created SNS topic: $SNS_TOPIC_ARN"
  else
    echo "SNS topic $SNS_TOPIC_NAME already exists: $SNS_TOPIC_ARN"
  fi

  # Subscribe email to the SNS topic
  echo "Subscribing $EMAIL to SNS topic $SNS_TOPIC_NAME..."
  aws sns subscribe --topic-arn "$SNS_TOPIC_ARN" --protocol email --notification-endpoint "$EMAIL" --no-cli-pager --no-cli-auto-prompt
  echo "Subscription request sent. Please check $EMAIL for confirmation."


  ASG_NAME=$(aws autoscaling describe-auto-scaling-instances \
    --instance-ids "$INSTANCE_ID" \
    --query "AutoScalingInstances[0].AutoScalingGroupName" \
    --output text)

  echo "ASG Name: $ASG_NAME"

  aws cloudwatch put-metric-alarm \
    --alarm-name "$TYPE : High CPU Utilization Alarm" \
    --metric-name CPUUtilization \
    --namespace "AWS/EC2" \
    --statistic "Maximum" \
    --period 300 \
    --threshold 70 \
    --comparison-operator GreaterThanThreshold \
    --dimensions Name=AutoScalingGroupName,Value=$ASG_NAME \
    --evaluation-periods 1 \
    --datapoints-to-alarm 1 \
    --treat-missing-data 'notBreaching' \
    --alarm-actions $SNS_TOPIC_ARN \
    --alarm-description "Alarm for average CPU Utilization on ASG $ASG_NAME" \
    --no-cli-pager --no-cli-auto-prompt
}

append_alarm_metric() {
    local instance_id=$1
    local type=$2
    local alarm_arn=$3

    create_asg_alarm $instance_id $type

    local alarm_title="$type : High CPU Utilization Alarm"
    
    METRICS_ARRAY=$(echo "$METRICS_ARRAY" | jq --arg alarm_title "$alarm_title" --arg alarm_arn "$alarm_arn" --arg alarm_region $REGION --argjson x_pos $x_position --argjson y_pos $y_position \
    '. + [
        {
            "height": 8,
            "width": 12,
            "y": $y_pos,
            "x": $x_pos,
            "type": "metric",
            "properties": {
                "title": $alarm_title,
                "annotations": {
                    "alarms": [
                        $alarm_arn
                    ]
                },
                "view": "timeSeries",
                "stacked": false
            }
        }
    ]')
    x_position=$((x_position + 12))
}

# Function to create CPU metrics for clusters
create_cpu_metrics() {
    local cluster_type=$1
    shift
    local cluster_names=("$@")

    for cluster in ${cluster_names[@]}; do
        if (( x_position >= 24 )); then
            x_position=0
            y_position=$((y_position + 6))
        fi
        # Append the metric once for each cluster
        append_cpu_metric "$cluster_type" "$cluster"
        x_position=$((x_position + 8))
    done
}

# Function to create EBS metrics
create_ebs_metrics() {
    local cluster_type=$1
    shift
    local volume_names=("$@")

    for volume in ${volume_names[@]}; do
        if (( x_position >= 24 )); then
            x_position=0
            y_position=$((y_position + 6))
        fi
        # Append the metric once for each volume
        append_ebs_metric "$cluster_type" "$volume"
        x_position=$((x_position + 8))
    done
}

# write a function to add markdown to cloudwatch dashboard 
add_markdown() {
    local text=$1

    echo $text

    METRICS_ARRAY=$(echo "$METRICS_ARRAY" | jq --arg text "$text" --argjson y_pos $y_position '. + [
            {
                "type": "text",
                "x": 0,
                "y": $y_pos,
                "width": 24,
                "height": 1,
                "properties": {
                    "markdown": "\n## \($text) \n",
                    "background": "solid"
                }
            }
        ]')
    y_position=$((y_position + 1))
}


create_dashboard() {
    METRICS_ARRAY="[]"
    x_position=0
    y_position=0

    echo "============"

    add_markdown "Service Metrics"

    append_latency_and_request_metric_once

    y_position=$((y_position + 8))

    add_markdown "Host Metrics"

    create_cpu_metrics ECS "${ECS_INSTANCE_IDS[@]}"
    create_cpu_metrics EKS "${EKS_INSTANCE_IDS[@]}"
    create_ebs_metrics ECS "${ECS_EBS_VOLUME_IDS[@]}"
    create_ebs_metrics EKS "${EKS_EBS_VOLUME_IDS[@]}"

    y_position=$((y_position + 6))
    x_position=0

    add_markdown "CloudWatch Logs for ECS and EKS"

    append_log_metric "/aws/containerinsights/${CLUSTER_NAME}/application" $REGION 
    append_log_metric "/ecs/pet-clinic-frontend-java-task" $REGION

    y_position=$((y_position + 6))
    x_position=0

    add_markdown "CloudWatch Alarms on ECS and EKS"

    append_alarm_metric $(echo $ECS_INSTANCE_IDS | awk '{print $1}') "ECS" "arn:aws:cloudwatch:$REGION:$ACCOUNT:alarm:ECS : High CPU Utilization Alarm" 
    append_alarm_metric $(echo $EKS_INSTANCE_IDS | awk '{print $1}') "EKS" "arn:aws:cloudwatch:$REGION:$ACCOUNT:alarm:EKS : High CPU Utilization Alarm"

    # Delete the dashboard if it exists
    aws cloudwatch delete-dashboards --dashboard-names "$DASHBOARD_NAME" 2>/dev/null

    aws cloudwatch put-dashboard --dashboard-name "$DASHBOARD_NAME" \
    --dashboard-body "$(jq -n --argjson metrics "$METRICS_ARRAY" '{ widgets: $metrics }')" --no-cli-pager --no-cli-auto-prompt

    echo "Dashboard '$DASHBOARD_NAME' has been created successfully."
}

ECS_INSTANCE_IDS=$(get_ecs_instance_ids)
EKS_INSTANCE_IDS=$(get_eks_instance_ids)
ECS_EBS_VOLUME_IDS=$(get_ebs_volumes ${ECS_INSTANCE_IDS[@]})
EKS_EBS_VOLUME_IDS=$(get_ebs_volumes ${EKS_INSTANCE_IDS[@]})

echo "ECS Instance IDs : $ECS_INSTANCE_IDS"
echo "EKS Instance IDs : $EKS_INSTANCE_IDS"

echo "ECS EBS Volume IDs : $ECS_EBS_VOLUME_IDS"
echo "EKS EBS Volume IDs : $EKS_EBS_VOLUME_IDS"

create_dashboard

# while true; do
#     echo "Sleeping for 5 minutes..."
#     sleep 300

#     NEW_ECS_INSTANCE_IDS=$(get_ecs_instance_ids)
#     NEW_EKS_INSTANCE_IDS=$(get_eks_instance_ids)
#     NEW_ECS_EBS_VOLUME_IDS=$(get_ebs_volumes ${NEW_ECS_INSTANCE_IDS[@]})
#     NEW_EKS_EBS_VOLUME_IDS=$(get_ebs_volumes ${NEW_EKS_INSTANCE_IDS[@]})

#     echo "New ECS Instance IDs : $NEW_ECS_INSTANCE_IDS"
#     echo "New EKS Instance IDs : $NEW_EKS_INSTANCE_IDS"
#     echo "New ECS EBS Volume IDs : $NEW_ECS_EBS_VOLUME_IDS"
#     echo "New EKS EBS Volume IDs : $NEW_EKS_EBS_VOLUME_IDS"

#     if [ "$NEW_ECS_INSTANCE_IDS" != "$ECS_INSTANCE_IDS" ] || 
#        [ "$NEW_EKS_INSTANCE_IDS" != "$EKS_INSTANCE_IDS" ] || 
#        [ "$NEW_ECS_EBS_VOLUME_IDS" != "$ECS_EBS_VOLUME_IDS" ] || 
#        [ "$NEW_EKS_EBS_VOLUME_IDS" != "$EKS_EBS_VOLUME_IDS" ]; then
#             ECS_INSTANCE_IDS=$NEW_ECS_INSTANCE_IDS
#             EKS_INSTANCE_IDS=$NEW_EKS_INSTANCE_IDS
#             ECS_EBS_VOLUME_IDS=$NEW_ECS_EBS_VOLUME_IDS
#             EKS_EBS_VOLUME_IDS=$NEW_EKS_EBS_VOLUME_IDS

#         echo "Changes detected in instance IDs or EBS volume IDs. Updating dashboard..."
#         create_dashboard
#     else 
#         echo "No changes detected in instance IDs or EBS volume IDs."
#     fi
# done

