#!/bin/sh

set -e

# Avoid "Your password does not satisfy the current policy requirements".
[ -z "${ZABBIX_PASSWD}" ] && ZABBIX_PASSWD=Zabbix_Passwd

zabbix_install()
{
  sudo dnf install -y policycoreutils-python-utils zabbix-server-mysql zabbix-web-mysql mod_ssl mariadb-server

  timezone=$(timedatectl | grep "Time zone:" | \
                awk -F':' '{ print $2 }' | awk '{ print $1 }')
  sudo sed -e 's/^post_max_size = .*/post_max_size = 16M/g' \
       -e 's/^max_execution_time = .*/max_execution_time = 300/g' \
       -e 's/^max_input_time = .*/max_input_time = 300/g' \
       -e "s:^;date.timezone =.*:date.timezone = \"${timezone}\":g" \
       -i /etc/php.ini

  sudo systemctl enable --now mariadb

  cat <<EOF | sudo mysql -uroot
create database zabbix;
grant all privileges on zabbix.* to zabbix@localhost identified by '${ZABBIX_PASSWD}';
exit
EOF

  for sql in schema.sql images.sql data.sql; do
    # shellcheck disable=SC2002
    cat /usr/share/zabbix-mysql/"${sql}" | \
      sudo mysql -uzabbix -p"${ZABBIX_PASSWD}" zabbix
  done

  sudo sed -e 's/# ListenPort=.*/ListenPort=10051/g' \
       -e "s/# DBPassword=.*/DBPassword=${ZABBIX_PASSWD}/g" \
       -i /etc/zabbix_server.conf

  # Skip setup.php
  cat <<EOF | sudo tee /etc/zabbix/web/zabbix.conf.php
<?php
// Zabbix GUI configuration file.
global \$DB;

\$DB['TYPE']     = 'MYSQL';
\$DB['SERVER']   = 'localhost';
\$DB['PORT']     = '0';
\$DB['DATABASE'] = 'zabbix';
\$DB['USER']     = 'zabbix';
\$DB['PASSWORD'] = '${ZABBIX_PASSWD}';

// Schema name. Used for IBM DB2 and PostgreSQL.
\$DB['SCHEMA'] = '';

\$ZBX_SERVER      = 'localhost';
\$ZBX_SERVER_PORT = '10051';
\$ZBX_SERVER_NAME = '';

\$IMAGE_FORMAT_DEFAULT = IMAGE_FORMAT_PNG;
?>
EOF

  sudo firewall-cmd --add-service=http --permanent
  sudo firewall-cmd --add-service=https --permanent
  sudo firewall-cmd --add-port=10050/tcp --permanent
  sudo firewall-cmd --add-port=10051/tcp --permanent
  sudo firewall-cmd --reload

  cat <<EOF > zabbix-server.te
module zabbix-server 1.0;
require {
  type zabbix_t;
  class process setrlimit;
}
#============= zabbix_t ==============
allow zabbix_t self:process setrlimit;
EOF
  checkmodule -M -m -o zabbix-server.mod zabbix-server.te
  semodule_package -m zabbix-server.mod -o zabbix-server.pp
  sudo semodule -i zabbix-server.pp
  rm -f zabbix-server.te zabbix-server.mod zabbix-server.pp

  sudo setsebool -P httpd_can_connect_zabbix 1

  sudo systemctl enable httpd zabbix-server-mysql
  sudo systemctl restart httpd zabbix-server

  # This Hostname is used for Host name in
  # Configuration -> Hosts -> Create Host.
  sudo dnf install -y zabbix-agent
  sudo sed -e "s/^Hostname=.*/Hostname=localhost/g" \
       -i /etc/zabbix_agentd.conf
  sudo systemctl enable zabbix-agent
  sudo systemctl start zabbix-agent
}

zabbix_install
