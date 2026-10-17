#!/bin/bash
set -euo pipefail   # stop script at first failure

BUCKET="$1"
KEY="$2"
REGION="eu-north-1"

dnf install -y python3-pip > /dev/null

aws s3 cp "s3://${BUCKET}/${KEY}" /tmp/app.tar.gz --region "$REGION"

rm -rf /opt/app/src
mkdir -p /opt/app/src
tar -xzf /tmp/app.tar.gz -C /opt/app/src

python3 -m venv /opt/app/venv
/opt/app/venv/bin/pip install -q -r /opt/app/src/requirements.txt

cat > /etc/systemd/system/app.service <<'EOF'
[Unit]
Description=Hello app
After=network.target

[Service]
WorkingDirectory=/opt/app/src
ExecStart=/opt/app/venv/bin/gunicorn -b 0.0.0.0:8080 app:app
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable app
systemctl restart app

for i in $(seq 1 15); do
  if curl -fs http://localhost:8080/health; then
    echo
    echo "healthy"
    exit 0
  fi
  sleep 2
done

echo "health check failed"
journalctl -u app --no-pager -n 30
exit 1
