#!/bin/bash

set -e

#--------------------------------------------------------------------
# Send the log output from this script to user-data.log, syslog, and the console
# From: https://alestic.com/2010/12/ec2-user-data-output/
#--------------------------------------------------------------------
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

#--------------------------------------------------------------------
# Set useful variables
#--------------------------------------------------------------------
export AWS_DEFAULT_REGION=${aws_region}
# IMDSv2
IMDS_TOKEN="$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")"
SELF_PRIVATE_IP="$(curl -sf -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
  http://169.254.169.254/latest/meta-data/local-ipv4)"

#--------------------------------------------------------------------
# Install Datadog Agent
#--------------------------------------------------------------------
export DD_API_KEY="$(aws ssm get-parameter --name "${ssm_path_datadog_api_key}" --with-decryption | jq -r '.Parameter.Value')"
export DD_LOGS_ENABLED=true
DD_AGENT_MAJOR_VERSION=7 bash -c "$(curl -L https://s3.amazonaws.com/dd-agent/scripts/install_script.sh)"

# Make sure logs are enabled in config (idempotent)
if grep -q '^[#[:space:]]*logs_enabled:' /etc/datadog-agent/datadog.yaml; then
  sed -i 's/^[#[:space:]]*logs_enabled:.*/logs_enabled: true/' /etc/datadog-agent/datadog.yaml
else
  echo 'logs_enabled: true' >> /etc/datadog-agent/datadog.yaml
fi

mkdir -p /etc/datadog-agent/conf.d/http_check.d
cat > /etc/datadog-agent/conf.d/http_check.d/conf.yaml <<EOF
init_config:

instances:
  - name: vault_http_check
    url: https://${cluster_fqdn}
EOF

# Journald log collection for vault.service
mkdir -p /etc/datadog-agent/conf.d/journald.d
cat >/etc/datadog-agent/conf.d/journald.d/conf.yaml <<'EOF'
logs:
  - type: journald
    service: vault
    source: vault
    filter_unit: vault.service
EOF

# Vault audit log file permissions for Datadog (optional but recommended)
dnf install -y acl
mkdir -p /var/log/vault
chown vault:vault /var/log/vault
touch /var/log/vault/audit.log
chown vault:vault /var/log/vault/audit.log
setfacl -m u:dd-agent:r /var/log/vault/audit.log || true

if ! grep -q '^tags:' /etc/datadog-agent/datadog.yaml; then
  cat >>/etc/datadog-agent/datadog.yaml <<EOF

tags:
  - "vault_cluster:${cluster_name}"
  - "env:${environment}"
  - "role:vault"
EOF
fi

systemctl restart datadog-agent

#--------------------------------------------------------------------
# Configure Logrotate ('EOF' so the subshell doesn't execute)
#--------------------------------------------------------------------
cat > /etc/logrotate.d/vault-audit <<'EOF'
"/var/log/vault/audit.log" {
  hourly
  rotate 2
  size 200M
  nodateext
  nocreate
  nocopy
  missingok
  notifempty
  compress
  postrotate
    kill -HUP $(cat /var/run/vault/vault.pid)
    setfacl -m u:dd-agent:r /var/log/vault/audit.log || true
  endscript
}
EOF

# setting hourly has no effect unless logrotate actually runs hourly using cron

# check if /etc/cron.daily/logrotate exists. This does not exist on Amazon Linux 2023
# if is does not exit, configure use systemd timer for hourly logrotate
if [ -f /etc/cron.daily/logrotate ]; then
  mv /etc/cron.daily/logrotate /etc/cron.hourly/
else
  # Create an hourly systemd timer + service for logrotate
cat >/etc/systemd/system/logrotate-hourly.service <<'EOF'
[Unit]
Description=Run logrotate hourly

[Service]
Type=oneshot
ExecStart=/usr/sbin/logrotate /etc/logrotate.conf
EOF

cat >/etc/systemd/system/logrotate-hourly.timer <<'EOF'
[Unit]
Description=Run logrotate hourly

[Timer]
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now logrotate-hourly.timer
fi


#--------------------------------------------------------------------
# Generate Vault's TLS certificate and key
#--------------------------------------------------------------------
openssl req \
  -x509 \
  -newkey rsa:2048 \
  -days 730 \
  -sha256 \
  -nodes \
  -subj "/CN=vault" \
  -keyout /etc/vault.d/vault-key.pem \
  -out /etc/vault.d/vault.pem

chown vault:vault /etc/vault.d/vault.pem /etc/vault.d/vault-key.pem
chmod 600 /etc/vault.d/vault.pem /etc/vault.d/vault-key.pem

#--------------------------------------------------------------------
# Configure and start Vault
#--------------------------------------------------------------------
mkdir -p /var/run/vault
chown vault:vault /var/run/vault

mkdir -p /var/log/vault
chown vault:vault /var/log/vault

cat <<EOF > /etc/vault.d/vault.hcl
ui = true
pid_file = "/var/run/vault/vault.pid"
cluster_name = "${cluster_name}"
log_format = "json"

storage "dynamodb" {
  ha_enabled = "true"
  region     = "${aws_region}"
  table      = "${dynamodb_table}"
}

seal "awskms" {
  region     = "${aws_region}"
  kms_key_id = "${kms_key_id}"
}

listener "tcp" {
  address         = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"
  tls_cert_file   = "/etc/vault.d/vault.pem"
  tls_key_file    = "/etc/vault.d/vault-key.pem"
}

telemetry {
  dogstatsd_addr = "127.0.0.1:8125"
  dogstatsd_tags = ${dogstatsd_tags}
}

cluster_addr  = "https://$SELF_PRIVATE_IP:8201"
api_addr      = "https://$SELF_PRIVATE_IP:8200"
EOF

systemctl enable vault
systemctl start vault
