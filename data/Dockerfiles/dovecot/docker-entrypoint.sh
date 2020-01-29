#!/bin/bash
set -e

# Wait for MySQL to warm-up
while ! mysqladmin status --socket=/var/run/mysqld/mysqld.sock -u${DBUSER} -p${DBPASS} --silent; do
  echo "Waiting for database to come up..."
  sleep 2
done

# Create missing directories
[[ ! -d /etc/dovecot/sql/ ]] && mkdir -p /etc/dovecot/sql/
[[ ! -d /etc/dovecot/lua/ ]] && mkdir -p /etc/dovecot/lua/
[[ ! -d /var/vmail/_garbage ]] && mkdir -p /var/vmail/_garbage
[[ ! -d /var/vmail/sieve ]] && mkdir -p /var/vmail/sieve
[[ ! -d /etc/sogo ]] && mkdir -p /etc/sogo
[[ ! -d /var/volatile ]] && mkdir -p /var/volatile

# Set Dovecot sql config parameters, escape " in db password
DBPASS=$(echo ${DBPASS} | sed 's/"/\\"/g')

# Create quota dict for Dovecot
if [[ "${MASTER}" =~ ^([yY][eE][sS]|[yY])+$ ]]; then
  QUOTA_TABLE=quota2
else
  QUOTA_TABLE=quota2replica
fi
cat <<EOF > /etc/dovecot/sql/dovecot-dict-sql-quota.conf
# Autogenerated by mailcow
connect = "host=/var/run/mysqld/mysqld.sock dbname=${DBNAME} user=${DBUSER} password=${DBPASS}"
map {
  pattern = priv/quota/storage
  table = ${QUOTA_TABLE}
  username_field = username
  value_field = bytes
}
map {
  pattern = priv/quota/messages
  table = ${QUOTA_TABLE}
  username_field = username
  value_field = messages
}
EOF

# Create dict used for sieve pre and postfilters
cat <<EOF > /etc/dovecot/sql/dovecot-dict-sql-sieve_before.conf
# Autogenerated by mailcow
connect = "host=/var/run/mysqld/mysqld.sock dbname=${DBNAME} user=${DBUSER} password=${DBPASS}"
map {
  pattern = priv/sieve/name/\$script_name
  table = sieve_before
  username_field = username
  value_field = id
  fields {
    script_name = \$script_name
  }
}
map {
  pattern = priv/sieve/data/\$id
  table = sieve_before
  username_field = username
  value_field = script_data
  fields {
    id = \$id
  }
}
EOF

cat <<EOF > /etc/dovecot/sql/dovecot-dict-sql-sieve_after.conf
# Autogenerated by mailcow
connect = "host=/var/run/mysqld/mysqld.sock dbname=${DBNAME} user=${DBUSER} password=${DBPASS}"
map {
  pattern = priv/sieve/name/\$script_name
  table = sieve_after
  username_field = username
  value_field = id
  fields {
    script_name = \$script_name
  }
}
map {
  pattern = priv/sieve/data/\$id
  table = sieve_after
  username_field = username
  value_field = script_data
  fields {
    id = \$id
  }
}
EOF

echo -n ${ACL_ANYONE} > /etc/dovecot/acl_anyone

if [[ "${SKIP_SOLR}" =~ ^([yY][eE][sS]|[yY])+$ ]]; then
echo -n 'quota acl zlib listescape mail_crypt mail_crypt_acl mail_log notify' > /etc/dovecot/mail_plugins
echo -n 'quota imap_quota imap_acl acl zlib imap_zlib imap_sieve listescape mail_crypt mail_crypt_acl notify mail_log' > /etc/dovecot/mail_plugins_imap
echo -n 'quota sieve acl zlib listescape mail_crypt mail_crypt_acl' > /etc/dovecot/mail_plugins_lmtp
else
echo -n 'quota acl zlib listescape mail_crypt mail_crypt_acl mail_log notify fts fts_solr' > /etc/dovecot/mail_plugins
echo -n 'quota imap_quota imap_acl acl zlib imap_zlib imap_sieve listescape mail_crypt mail_crypt_acl notify mail_log fts fts_solr' > /etc/dovecot/mail_plugins_imap
echo -n 'quota sieve acl zlib listescape mail_crypt mail_crypt_acl fts fts_solr' > /etc/dovecot/mail_plugins_lmtp
fi
chmod 644 /etc/dovecot/mail_plugins /etc/dovecot/mail_plugins_imap /etc/dovecot/mail_plugins_lmtp /templates/quarantine.tpl

cat <<EOF > /etc/dovecot/sql/dovecot-dict-sql-userdb.conf
# Autogenerated by mailcow
driver = mysql
connect = "host=/var/run/mysqld/mysqld.sock dbname=${DBNAME} user=${DBUSER} password=${DBPASS}"
user_query = SELECT CONCAT(JSON_UNQUOTE(JSON_EXTRACT(attributes, '$.mailbox_format')), mailbox_path_prefix, '%d/%n/${MAILDIR_SUB}:VOLATILEDIR=/var/volatile/%u') AS mail, 5000 AS uid, 5000 AS gid, concat('*:bytes=', quota) AS quota_rule FROM mailbox WHERE username = '%u' AND active = '1'
iterate_query = SELECT username FROM mailbox WHERE active='1';
EOF

# Create pass dict for Dovecot
cat <<EOF > /etc/dovecot/sql/dovecot-dict-sql-passdb.conf
# Autogenerated by mailcow
driver = mysql
connect = "host=/var/run/mysqld/mysqld.sock dbname=${DBNAME} user=${DBUSER} password=${DBPASS}"
default_pass_scheme = SSHA256
password_query = SELECT password FROM mailbox WHERE active = '1' AND username = '%u' AND domain IN (SELECT domain FROM domain WHERE domain='%d' AND active='1') AND JSON_EXTRACT(attributes, '$.force_pw_update') NOT LIKE '%%1%%'
EOF

cat <<EOF > /etc/dovecot/lua/app-passdb.lua
function auth_password_verify(req, pass)
  if req.domain == nil then
    return dovecot.auth.PASSDB_RESULT_USER_UNKNOWN, "No such user"
  end
  local cur,errorString = con:execute(string.format([[SELECT mailbox, password FROM app_passwd
    WHERE mailbox = '%s'
      AND active = '1'
      AND domain IN (SELECT domain FROM domain WHERE domain='%s' AND active='1')]], con:escape(req.user), con:escape(req.domain)))
  local row = cur:fetch ({}, "a")
  while row do
    if req.password_verify(req, row.password, pass) == 1 then
      cur:close()
      return dovecot.auth.PASSDB_RESULT_OK, "password=" .. pass
    end
    row = cur:fetch (row, "a")
  end
  return dovecot.auth.PASSDB_RESULT_USER_UNKNOWN, "No such user"
end

function script_init()
  mysql = require "luasql.mysql"
  env  = mysql.mysql()
  con = env:connect("__DBNAME__","__DBUSER__","__DBPASS__","localhost")
  return 0
end

function script_deinit()
  con:close()
  env:close()
end
EOF

# Migrate old sieve_after file
[[ -f /etc/dovecot/sieve_after ]] && mv /etc/dovecot/sieve_after /etc/dovecot/global_sieve_after
# Create global sieve scripts
cat /etc/dovecot/global_sieve_after > /var/vmail/sieve/global_sieve_after.sieve
cat /etc/dovecot/global_sieve_before > /var/vmail/sieve/global_sieve_before.sieve

# Check permissions of vmail/attachments directory.
# Do not do this every start-up, it may take a very long time. So we use a stat check here.
if [[ $(stat -c %U /var/vmail/) != "vmail" ]] ; then chown -R vmail:vmail /var/vmail ; fi
if [[ $(stat -c %U /var/vmail/_garbage) != "vmail" ]] ; then chown -R vmail:vmail /var/vmail/_garbage ; fi
if [[ $(stat -c %U /var/attachments) != "vmail" ]] ; then chown -R vmail:vmail /var/attachments ; fi

# Cleanup random user maildirs
rm -rf /var/vmail/mailcow.local/*

# create sni configuration
echo "" > /etc/dovecot/sni.conf
for cert_dir in /etc/ssl/mail/*/ ; do
  if [[ ! -f ${cert_dir}domains ]] || [[ ! -f ${cert_dir}cert.pem ]] || [[ ! -f ${cert_dir}key.pem ]]; then
    continue
  fi
  domains=($(cat ${cert_dir}domains))
  for domain in ${domains[@]}; do
    echo 'local_name '${domain}' {' >> /etc/dovecot/sni.conf;
    echo '  ssl_cert = <'${cert_dir}'cert.pem' >> /etc/dovecot/sni.conf;
    echo '  ssl_key = <'${cert_dir}'key.pem' >> /etc/dovecot/sni.conf;
    echo '}' >> /etc/dovecot/sni.conf;
  done
done

# Create random master for SOGo sieve features
RAND_USER=$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 16 | head -n 1)
RAND_PASS=$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 24 | head -n 1)

echo ${RAND_USER}@mailcow.local:{SHA1}$(echo -n ${RAND_PASS} | sha1sum | awk '{print $1}') > /etc/dovecot/dovecot-master.passwd
echo ${RAND_USER}@mailcow.local::5000:5000:::: > /etc/dovecot/dovecot-master.userdb
echo ${RAND_USER}@mailcow.local:${RAND_PASS} > /etc/sogo/sieve.creds

if [[ -z ${MAILDIR_SUB} ]]; then
  MAILDIR_SUB_SHARED=
else
  MAILDIR_SUB_SHARED=/${MAILDIR_SUB}
fi
cat <<EOF > /etc/dovecot/shared_namespace.conf
# Autogenerated by mailcow
namespace {
    type = shared
    separator = /
    prefix = Shared/%%u/
    location = maildir:%%h${MAILDIR_SUB_SHARED}:INDEX=~${MAILDIR_SUB_SHARED}/Shared/%%u
    subscriptions = no
    list = children
}
EOF

if [[ "${ALLOW_ADMIN_EMAIL_LOGIN}" =~ ^([yY][eE][sS]|[yY])+$ ]]; then
    # Create random master Password for SOGo 'login as user' via proxy auth
    RAND_PASS=$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 32 | head -n 1)
    echo -n ${RAND_PASS} > /etc/phpfpm/sogo-sso.pass
    cat <<EOF > /etc/dovecot/sogo-sso.conf
# Autogenerated by mailcow
passdb {
  driver = static
  args = allow_real_nets=${IPV4_NETWORK}.248/32 password={plain}${RAND_PASS}
}
EOF
else
    rm -f /etc/dovecot/sogo-sso.pass
    rm -f /etc/dovecot/sogo-sso.conf
fi

# Hard-code env vars to scripts due to cron not passing them to the scripts
sed -i "s/__DBUSER__/${DBUSER}/g" /usr/local/bin/imapsync_cron.pl /usr/local/bin/quarantine_notify.py /usr/local/bin/clean_q_aged.sh /etc/dovecot/lua/app-passdb.lua
sed -i "s/__DBPASS__/${DBPASS}/g" /usr/local/bin/imapsync_cron.pl /usr/local/bin/quarantine_notify.py /usr/local/bin/clean_q_aged.sh /etc/dovecot/lua/app-passdb.lua
sed -i "s/__DBNAME__/${DBNAME}/g" /usr/local/bin/imapsync_cron.pl /usr/local/bin/quarantine_notify.py /usr/local/bin/clean_q_aged.sh /etc/dovecot/lua/app-passdb.lua
sed -i "s/__LOG_LINES__/${LOG_LINES}/g" /usr/local/bin/trim_logs.sh
if [[ "${MASTER}" =~ ^([yY][eE][sS]|[yY])+$ ]]; then
# Toggling MASTER will result in a rebuild of containers, so the quota script will be recreated
cat <<'EOF' > /usr/local/bin/quota_notify.py
#!/usr/bin/python3
import sys
sys.exit()
EOF
fi

# 401 is user dovecot
if [[ ! -s /mail_crypt/ecprivkey.pem || ! -s /mail_crypt/ecpubkey.pem ]]; then
	openssl ecparam -name prime256v1 -genkey | openssl pkey -out /mail_crypt/ecprivkey.pem
	openssl pkey -in /mail_crypt/ecprivkey.pem -pubout -out /mail_crypt/ecpubkey.pem
	chown 401 /mail_crypt/ecprivkey.pem /mail_crypt/ecpubkey.pem
else
	chown 401 /mail_crypt/ecprivkey.pem /mail_crypt/ecpubkey.pem
fi

# Compile sieve scripts
sievec /var/vmail/sieve/global_sieve_before.sieve
sievec /var/vmail/sieve/global_sieve_after.sieve
sievec /usr/lib/dovecot/sieve/report-spam.sieve
sievec /usr/lib/dovecot/sieve/report-ham.sieve

# Fix permissions
chown root:root /etc/dovecot/sql/*.conf
chown root:dovecot /etc/dovecot/sql/dovecot-dict-sql-sieve* /etc/dovecot/sql/dovecot-dict-sql-quota* /etc/dovecot/lua/app-passdb.lua
chmod 640 /etc/dovecot/sql/*.conf /etc/dovecot/lua/app-passdb.lua
chown -R vmail:vmail /var/vmail/sieve
chown -R vmail:vmail /var/volatile
adduser vmail tty
chmod g+rw /dev/console
chown root:tty /dev/console
chmod +x /usr/lib/dovecot/sieve/rspamd-pipe-ham \
  /usr/lib/dovecot/sieve/rspamd-pipe-spam \
  /usr/local/bin/imapsync_cron.pl \
  /usr/local/bin/postlogin.sh \
  /usr/local/bin/imapsync \
  /usr/local/bin/trim_logs.sh \
  /usr/local/bin/sa-rules.sh \
  /usr/local/bin/clean_q_aged.sh \
  /usr/local/bin/maildir_gc.sh \
  /usr/local/sbin/stop-supervisor.sh \
  /usr/local/bin/quota_notify.py

if [[ "${MASTER}" =~ ^([yY][eE][sS]|[yY])+$ ]]; then
# Setup cronjobs
echo '* * * * *    root  /usr/local/bin/imapsync_cron.pl 2>&1 | /usr/bin/logger' > /etc/cron.d/imapsync
#echo '30 3 * * *   vmail /usr/local/bin/doveadm quota recalc -A' > /etc/cron.d/dovecot-sync
echo '* * * * *    vmail /usr/local/bin/trim_logs.sh >> /dev/console 2>&1' > /etc/cron.d/trim_logs
echo '25 * * * *   vmail /usr/local/bin/maildir_gc.sh >> /dev/console 2>&1' > /etc/cron.d/maildir_gc
echo '30 1 * * *   root  /usr/local/bin/sa-rules.sh  >> /dev/console 2>&1' > /etc/cron.d/sa-rules
echo '0 2 * * *    root  /usr/bin/curl http://solr:8983/solr/dovecot-fts/update?optimize=true >> /dev/console 2>&1' > /etc/cron.d/solr-optimize
echo '*/20 * * * * vmail /usr/local/bin/quarantine_notify.py >> /dev/console 2>&1' > /etc/cron.d/quarantine_notify
echo '15 4 * * * vmail /usr/local/bin/clean_q_aged.sh >> /dev/console 2>&1' > /etc/cron.d/clean_q_aged
# Fix more than 1 hardlink issue
touch /etc/crontab /etc/cron.*/*
else
echo '25 * * * *   vmail /usr/local/bin/maildir_gc.sh >> /dev/console 2>&1' > /etc/cron.d/maildir_gc
echo '30 1 * * *   root  /usr/local/bin/sa-rules.sh  >> /dev/console 2>&1' > /etc/cron.d/sa-rules
echo '0 2 * * *    root  /usr/bin/curl http://solr:8983/solr/dovecot-fts/update?optimize=true >> /dev/console 2>&1' > /etc/cron.d/solr-optimize
fi

# Clean old PID if any
[[ -f /var/run/dovecot/master.pid ]] && rm /var/run/dovecot/master.pid

# Clean stopped imapsync jobs
rm -f /tmp/imapsync_busy.lock
IMAPSYNC_TABLE=$(mysql --socket=/var/run/mysqld/mysqld.sock -u ${DBUSER} -p${DBPASS} ${DBNAME} -e "SHOW TABLES LIKE 'imapsync'" -Bs)
[[ ! -z ${IMAPSYNC_TABLE} ]] && mysql --socket=/var/run/mysqld/mysqld.sock -u ${DBUSER} -p${DBPASS} ${DBNAME} -e "UPDATE imapsync SET is_running='0'"

# Envsubst maildir_gc
echo "$(envsubst < /usr/local/bin/maildir_gc.sh)" > /usr/local/bin/maildir_gc.sh

PUBKEY_MCRYPT=$(doveconf -P | grep -i mail_crypt_global_public_key | cut -d '<' -f2)
if [ -f ${PUBKEY_MCRYPT} ]; then
  GUID=$(cat <(echo ${MAILCOW_HOSTNAME}) /mail_crypt/ecpubkey.pem | sha256sum | cut -d ' ' -f1 | tr -cd "[a-fA-F0-9.:/] ")
  if [ ${#GUID} -eq 64 ]; then
    mysql --socket=/var/run/mysqld/mysqld.sock -u ${DBUSER} -p${DBPASS} ${DBNAME} << EOF
REPLACE INTO versions (application, version) VALUES ("GUID", "${GUID}");
EOF
  else
    mysql --socket=/var/run/mysqld/mysqld.sock -u ${DBUSER} -p${DBPASS} ${DBNAME} << EOF
REPLACE INTO versions (application, version) VALUES ("GUID", "INVALID");
EOF
  fi
fi

# Collect SA rules once now
/usr/local/bin/sa-rules.sh

# Run hooks
for file in /hooks/*; do
  if [ -x "${file}" ]; then
    echo "Running hook ${file}"
    "${file}"
  fi
done

# For some strange, unknown and stupid reason, Dovecot may run into a race condition, when this file is not touched before it is read by dovecot/auth
# May be related to something inside Docker, I seriously don't know
touch /etc/dovecot/lua/app-passdb.lua

exec "$@"
