#!/bin/bash -xe

cd /tmp

# Install jq
yum -y install jq

# Populate some variables from meta-data and tags
INSTANCE_ID=$(curl http://169.254.169.254/latest/meta-data/instance-id)
REGION=$(curl http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r .region)
NAME=$(aws ec2 describe-tags --region us-east-1 --filters "Name=key,Values=Name" "Name=resource-id,Values=${INSTANCE_ID}" | jq .Tags[0].Value -r)
STACK_NAME=$(aws ec2 describe-tags --region us-east-1 --filters "Name=key,Values=StackName" "Name=resource-id,Values=${INSTANCE_ID}" | jq .Tags[0].Value -r)

# Update the motd banner
if ! [ -z "${MOTD_BANNER}" ]
then
    wget --no-cache -O /etc/update-motd.d/30-banner ${MOTD_BANNER}
    update-motd --force
    update-motd --disable
else 
    echo "No MOTD_BANNER specified, skipping motd configuration"
fi

# Create user accounts for administrators
wget --no-cache https://raw.githubusercontent.com/mcsheaj/aws-ec2-ssh/master/install.sh
chmod 755 install.sh
if ! [ -z "${ADMIN_GROUP}" ]
then
    yum -y install git
    ./install.sh -i ${ADMIN_GROUP} -s ${ADMIN_GROUP}
else 
    yum -y install git
    ./install.sh -s '##ALL##'
fi

# Update the instance name to include the stack name
if [[ ${NAME} != *-${STACK_NAME} ]]
then
    NEW_NAME="${NAME}-${STACK_NAME}"
    aws ec2 create-tags --resources ${INSTANCE_ID} --tags Key=Name,Value=$NEW_NAME --region $REGION
else
    NEW_NAME=${NAME}
fi

# Print a list of open ports
lsof -i -n -P

# Run system updates
yum -y update

# Delete the ec2-user and its home directory
userdel ec2-user || true
rm -rf /home/ec2-user || true

# Call cfn-init, which reads the launch configration metadata and uses it to
# configure and runs cfn-hup as a service, so we can get a script run on updates to the metadata
/opt/aws/bin/cfn-init -v --stack ${STACK_NAME} --resource LaunchConfig --configsets cfn_install --region ${REGION}

# Send a signal indicating we're done
/opt/aws/bin/cfn-signal -e $? --stack ${STACK_NAME} --resource BastionScalingGroup --region ${REGION} || true
