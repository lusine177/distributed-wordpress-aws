#!/bin/bash
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1
set -x  # print every command as it runs — critical for debugging

# Configuration Variables
DB_NAME="wordpress"
DB_USER="admin"
DB_PASSWORD="******" #your password
DB_HOST="lusine-rds.ctyqmu2cqd34.eu-north-1.rds.amazonaws.com"
EFS_ID="fs-0741c3c690f9c778d"
REGION="eu-north-1"
export DEBIAN_FRONTEND=noninteractive

# 1. Update and Install Dependencies
apt-get update -y
apt-get install -y \
  apache2 php libapache2-mod-php php-mysql php-gd php-mbstring php-xml php-curl \
  nfs-common binutils wget tar curl

a2enmod rewrite
systemctl enable apache2
systemctl start apache2

# 2. Mount EFS — with wider retry window to survive DNS propagation delay on fresh boots
mkdir -p /var/www/html
EFS_DNS="${EFS_ID}.efs.${REGION}.amazonaws.com"

MOUNT_OK=0
for i in $(seq 1 20); do
  if mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport "${EFS_DNS}:/" /var/www/html; then
    MOUNT_OK=1
    echo "EFS mounted successfully on attempt $i"
    break
  fi
  echo "EFS mount attempt $i failed, retrying in 20s..."
  sleep 20
done

if [ "$MOUNT_OK" -ne 1 ]; then
  echo "FATAL: EFS mount failed after 20 attempts. Check EFS SG rules and DNS resolution."
  exit 1
fi

if ! grep -qs "${EFS_ID}" /etc/fstab; then
  echo "${EFS_DNS}:/ /var/www/html nfs4 defaults,_netdev,nofail,nfsvers=4.1,noresvport 0 0" >> /etc/fstab
fi

# 3. Download & Configure WordPress
if [ ! -f /var/www/html/wp-config.php ]; then
  echo "Installing WordPress..."
  cd /tmp
  if ! wget -O latest.tar.gz https://wordpress.org/latest.tar.gz; then
    echo "FATAL: wget of WordPress failed"; exit 1
  fi
  tar -xzf latest.tar.gz
  rm -f /var/www/html/index.html
  cp -r /tmp/wordpress/. /var/www/html/

  cp /var/www/html/wp-config-sample.php /var/www/html/wp-config.php
  sed -i "s/database_name_here/${DB_NAME}/" /var/www/html/wp-config.php
  sed -i "s/username_here/${DB_USER}/" /var/www/html/wp-config.php
  sed -i "s/password_here/${DB_PASSWORD}/" /var/www/html/wp-config.php
  sed -i "s/localhost/${DB_HOST}/" /var/www/html/wp-config.php

  SALT=$(curl -s https://api.wordpress.org/secret-key/1.1/salt/)
  printf '%s\n' "g/'put your unique phrase here'/d" a "$SALT" . w | ed -s /var/www/html/wp-config.php
else
  echo "wp-config.php already exists on EFS — skipping install"
fi

# 4. Apache config
cat <<EOF > /etc/apache2/conf-available/wordpress.conf
<Directory /var/www/html/>
    Options Indexes FollowSymLinks
    AllowOverride All
    Require all granted
</Directory>
EOF
a2enconf wordpress

# 5. Permissions & restart
chown -R www-data:www-data /var/www/html
find /var/www/html -type d -exec chmod 755 {} \;
find /var/www/html -type f -exec chmod 644 {} \;
systemctl restart apache2

echo "WordPress setup complete!"
