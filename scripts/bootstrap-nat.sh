#!/bin/bash -xe

cd /tmp

# Populate some variables from meta-data and tags
INSTANCE_ID=$(curl http://169.254.169.254/latest/meta-data/instance-id)
REGION=$(curl http://169.254.169.254/latest/dynamic/instance-identity/document|grep region|awk -F\" '{print $4}')

# Create a bootstrap tag
BOOTSTRAP=$(date +"BEGIN: %Y-%m-%d %H:%M:%S %Z")
aws ec2 create-tags --resources ${INSTANCE_ID} --tags "Key=Bootstrap,Value=${BOOTSTRAP}" --region ${REGION}

# Create user accounts for administrators
wget --no-cache https://raw.githubusercontent.com/mcsheaj/aws-ec2-ssh/master/install.sh
chmod 755 install.sh
yum -y install git
if ! [ -z "${ADMIN_GROUP}" ]
then
    ./install.sh -i ${ADMIN_GROUP} -s ${ADMIN_GROUP}
else 
    ./install.sh -s '##ALL##'
fi
BOOTSTRAP=$(date +"${BOOTSTRAP}; SSHEC2: %Y-%m-%d %H:%M:%S %Z")
aws ec2 create-tags --resources ${INSTANCE_ID} --tags "Key=Bootstrap,Value=${BOOTSTRAP}" --region ${REGION}

# Install jq
yum -y install jq

# Populate some variables from CLI (need jq first)
NAME=$(aws ec2 describe-tags --region us-east-1 --filters "Name=key,Values=Name" "Name=resource-id,Values=$INSTANCE_ID" --output json | jq .Tags[0].Value -r)
STACK_NAME=$(aws ec2 describe-tags --region us-east-1 --filters "Name=key,Values=StackName" "Name=resource-id,Values=$INSTANCE_ID" --output json | jq .Tags[0].Value -r)

# Update the motd banner
if ! [ -z "${MOTD_BANNER}" ]
then
    wget --no-cache -O /etc/update-motd.d/30-banner ${MOTD_BANNER}
    update-motd --force
    update-motd --disable
else 
    echo "No MOTD_BANNER specified, skipping motd configuration"
fi

# Update the instance name to include the stack name
if [[ ${NAME} != *-${STACK_NAME} ]]
then
    NEW_NAME="${NAME}-${STACK_NAME}"
    aws ec2 create-tags --resources ${INSTANCE_ID} --tags "Key=Name,Value=$NEW_NAME" --region ${REGION}
else
    NEW_NAME=${NAME}
fi

# Disable source/destination IP check so forwarding will work
aws ec2 modify-instance-attribute --instance-id ${INSTANCE_ID} --source-dest-check "{\"Value\": false}" --region ${REGION}

# Turn on IPV4 forwarding
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
sysctl -p

# Install the RedHat epel yum repo
yum -y install https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm

# Install iptables-service and fail2ban from the epel repo
yum -y install iptables-services fail2ban

# Get the VPC CIDR from metadata
MAC_ADDRESS=$(curl http://169.254.169.254/latest/meta-data/network/interfaces/macs/)
VPC_CIDR=$(curl http://169.254.169.254/latest/meta-data/network/interfaces/macs/${MAC_ADDRESS}/vpc-ipv4-cidr-block)

# Enable iptables to start on boot, and start it now
systemctl enable iptables
systemctl start iptables

# Flush iptables
iptables -F

# Enable nat in iptables for our VPC CIDDR
iptables -t nat -A POSTROUTING -o eth0 -s ${VPC_CIDR} -j MASQUERADE

# Configure iptables:
# 1. accept anything on the loopback adapter
# 2. accept incoming packets that belong to a connection that has already been established (using the state module)
# 3. accept udp on ports 67:68 (DHCP, only from our CIDR)
# 3. accept tcp on port 22 (SSH, only from our CIDR)
# 4. accept tcp on port 80 (yum, only from our CIDR)
# 5. accept tcp on port 443 (yum, only from our CIDR)
# 4. drop anything else
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A INPUT -p udp --dport 67:68 --sport 67:68 -s ${VPC_CIDR} -j ACCEPT
iptables -A INPUT -p tcp -m tcp --dport 22 -s ${VPC_CIDR} -j ACCEPT
iptables -A INPUT -p tcp -m tcp --dport 80 -s ${VPC_CIDR} -j ACCEPT
iptables -A INPUT -p tcp -m tcp --dport 443 -s ${VPC_CIDR} -j ACCEPT
iptables -A INPUT -j DROP

# And persist the iptables config
iptables-save > /etc/sysconfig/iptables

# Download the script to update the default routes on the private networks and run it
wget --no-cache https://raw.githubusercontent.com/mcsheaj/wordpress-high-availability-blog/master/scripts/aws-auto-healing-nat.sh
mv aws-auto-healing-nat.sh /sbin
chmod 700 /sbin/aws-auto-healing-nat.sh
/sbin/aws-auto-healing-nat.sh

# Reset the private route tables on boot
echo "/sbin/aws-auto-healing-nat.sh" >> /etc/rc.d/rc.local
chmod 700 /etc/rc.d/rc.local

# Run system updates
yum -y update

# Call cfn-init, which reads the launch configration metadata and uses it to
# configure and runs cfn-hup as a service, so we can get a script run on updates to the metadata
/opt/aws/bin/cfn-init -v --stack ${STACK_NAME} --resource LaunchConfig --configsets cfn_install --region ${REGION}

# Send a signal indicating we're done
/opt/aws/bin/cfn-signal -e $? --stack ${STACK_NAME} --resource NatScalingGroup --region ${REGION} || true

# Update the bootstrap tag
BOOTSTRAP=$(date +"${BOOTSTRAP}; END: %Y-%m-%d %H:%M:%S %Z")
aws ec2 create-tags --resources ${INSTANCE_ID} --tags "Key=Bootstrap,Value=${BOOTSTRAP}" --region ${REGION}
