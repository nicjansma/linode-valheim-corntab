#!/bin/bash

echo ---
echo linode-valheim-corntab
echo

#
# apply ENV vars
#

#
# Linode
#
echo Configuring Linode CLI...

cat <<EOF > /root/.config/linode-cli
[DEFAULT]
default-user = $LINODE_USER

[nicjansma]
token = $LINODE_USER_TOKEN
region = $LINODE_REGION
type = $LINODE_TYPE
image = $LINODE_IMAGE
authorized_users = $LINODE_USER
EOF

#
# AWS
#
echo Configuring AWS...



# ensure supercronic log dir
mkdir -p /var/log/supercronic
chmod 755 /var/log/supercronic

echo Setup complete!

echo Launching supercronic
/usr/local/bin/supercronic /etc/crontab
