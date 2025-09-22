#!/bin/bash

# Update system
apt-get update -y
apt-get upgrade -y

# Install Docker
curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh
usermod -aG docker ubuntu

# Install Docker Compose
curl -L "https://github.com/docker/compose/releases/download/v2.21.0/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# Install nginx (as reverse proxy)
apt-get install -y nginx

# Create nginx config for SimplCommerce
cat > /etc/nginx/sites-available/simplcommerce << 'EOF'
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://localhost:5000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection keep-alive;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_cache_bypass $http_upgrade;
        proxy_buffering off;
        client_max_body_size 100M;
    }
}
EOF

# Enable the site
ln -sf /etc/nginx/sites-available/simplcommerce /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

# Test and restart nginx
nginx -t
systemctl restart nginx
systemctl enable nginx

# Install AWS CLI and SSM Agent
apt-get install -y awscli
snap install amazon-ssm-agent --classic
systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent.service
systemctl start snap.amazon-ssm-agent.amazon-ssm-agent.service

# Create data directory
mkdir -p /app/data

# Create database connection string
DB_CONNECTION_STRING="Host=${db_host};Database=${db_name};Username=${db_username};Password=${db_password};Port=5432;SSL Mode=Require;Trust Server Certificate=true;"

# Get ECR login token and login to ECR
aws ecr get-login-password --region ${aws_region} | docker login --username AWS --password-stdin ${ecr_registry}

# Pull and run SimplCommerce container
docker pull ${docker_image}

# Run the container with PostgreSQL connection
docker run -d \
  --name simplcommerce \
  --restart unless-stopped \
  -p 5000:5000 \
  -e ConnectionStrings__DefaultConnection="$DB_CONNECTION_STRING" \
  -e ASPNETCORE_ENVIRONMENT=Production \
  -e ASPNETCORE_URLS=http://+:5000 \
  -v /app/data:/app/data \
  ${docker_image}

# Create a simple health check script
cat > /usr/local/bin/simplcommerce-health.sh << 'EOF'
#!/bin/bash
if curl -f -s http://localhost:5000/health > /dev/null 2>&1; then
    echo "SimplCommerce is healthy"
    exit 0
else
    echo "SimplCommerce is unhealthy, restarting container..."
    docker restart simplcommerce
    exit 1
fi
EOF

chmod +x /usr/local/bin/simplcommerce-health.sh

# Add health check to cron (every 5 minutes)
echo "*/5 * * * * /usr/local/bin/simplcommerce-health.sh >> /var/log/simplcommerce-health.log 2>&1" | crontab -

# Create log rotation for health check logs
cat > /etc/logrotate.d/simplcommerce << 'EOF'
/var/log/simplcommerce-health.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
}
EOF

echo "SimplCommerce deployment completed successfully!"
