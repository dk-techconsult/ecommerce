#!/bin/bash

# Update system
apt-get update -y
apt-get upgrade -y

# Install Docker
curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh
usermod -aG docker ubuntu

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

# Create data directory
mkdir -p /app/data

# Create database connection string
DB_CONNECTION_STRING="Host=${db_host};Database=${db_name};Username=${db_username};Password=${db_password};Port=5432;SSL Mode=Require;Trust Server Certificate=true;"

# Pull and run SimplCommerce container with pre-built image
docker pull docker.io/simplcommerce/ci-build:latest

# Run the container with PostgreSQL connection
docker run -d \
  --name simplcommerce \
  --restart unless-stopped \
  -p 5000:5000 \
  -e ConnectionStrings__DefaultConnection="$DB_CONNECTION_STRING" \
  -e ASPNETCORE_ENVIRONMENT=Production \
  -e ASPNETCORE_URLS=http://+:5000 \
  -v /app/data:/app/data \
  docker.io/simplcommerce/ci-build:latest

# Create a simple health check script
cat > /usr/local/bin/simplcommerce-health.sh << 'EOF'
#!/bin/bash
if curl -f -s http://localhost:5000 > /dev/null 2>&1; then
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

echo "SimplCommerce deployment completed successfully!"
