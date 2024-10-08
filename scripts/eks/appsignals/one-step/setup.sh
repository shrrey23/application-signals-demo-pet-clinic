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

check_if_step_failed_and_exit() {
  if [ $? -ne 0 ]; then
    echo $1
    exit 1
  fi
}

# create cluster
../create-cluster.sh $CLUSTER_NAME $REGION
check_if_step_failed_and_exit "There was an error creating cluster $CLUSTER_NAME in region $REGION, exiting"

# enable application signals auto-instrumentation
../enable-app-signals.sh $CLUSTER_NAME $REGION $NAMESPACE
check_if_step_failed_and_exit "There was an error enabling app signals with namespace $NAMESPACE, exiting"

# enable aws-ebs-csi-driver 
../enable-ebs-csi-driver.sh $CLUSTER_NAME $REGION $NAMESPACE
check_if_step_failed_and_exit "There was an error enabling aws-ebs-csi-driver with namespace $NAMESPACE, exiting"

# deploy sample application
../deploy-sample-app.sh $CLUSTER_NAME $REGION $NAMESPACE
check_if_step_failed_and_exit "There was an error deploying the sample app, exiting"

Check if the current context points to the new cluster in the correct region
kub_config=$(kubectl config current-context)
if [[ $kub_config != *"$CLUSTER_NAME"* ]] || [[ $kub_config != *"$REGION"* ]]; then
    echo "Your current cluster context is not set to $CLUSTER_NAME in $REGION. To get the endpoint of the sample app update your context then run
    kubectl get svc -n ingress-nginx | grep \"ingress-nginx\" | awk '{print \$4}'"
    exit 1
fi

# Save the endpoint URL to a variable
endpoint=$(kubectl get svc -n ingress-nginx | grep "ingress-nginx" | awk '{print $4}')

# # Create ECS cluster and service to deploy front-end application
cd ../../../ecs
./setup-ecs.sh $CLUSTER_NAME $REGION $endpoint $ACCOUNT

nlb_endpoint=$(aws elbv2 describe-load-balancers --names pet-clinic-nlb --query 'LoadBalancers[0].DNSName' --output text)

echo "==============================="
echo "Visit the application on the endpoint: $nlb_endpoint"
echo "==============================="

# deploy traffic generator
cd ../eks/appsignals/one-step
../deploy-traffic-generator.sh $CLUSTER_NAME $REGION $nlb_endpoint $NAMESPACE
check_if_step_failed_and_exit "There was an error deploying the traffic generator, exiting"

# create canaries
../create-canaries.sh $REGION "create" $nlb_endpoint
check_if_step_failed_and_exit "There was an error creating the canaries, exiting"
