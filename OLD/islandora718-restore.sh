#!/bin/bash

USAGE="Usage: $(basename $0) <backup files or blank for list>"

aws=/usr/bin/aws

if [ ! -x ${aws} ]; then
	echo "aws is missing"
	exit
fi

drush=/home/ubuntu/.config/composer/vendor/bin/drush

if [ ! -x ${drush} ]; then
	echo "drush is missing"
	exit
fi

rsync=/usr/bin/rsync

if [ ! -x ${rsync} ]; then
	echo "rsync is missing"
	exit
fi

rsync="rsync -a --delete"

backups=chs-backups

if [ $# -eq 0 ]; then
	printf "\n"
	printf "$USAGE\n"
	printf "\n"
	printf "Possible archives:\n"
	${aws} s3 ls s3://${backups}/ | sed 's| *PRE ||' | sed 's|/$||' | sort | sed 's|^|    |'
	exit 2
fi

backup=$1

if [ "X`${aws} s3 ls s3://${backups}/${backup}/`" = 'X' ]; then
	echo "Archive not found: ${backup}"
	exit 2 
fi

printf "Upgrade from ${backup} ? (y or n): "
read ln

if [ ${ln} != 'y' ]; then
	exit
fi

#
# Fedora
#

fedora_restore=1

if [ $fedora_restore -eq 1 ]; then
	if [ ! -d /usr/local/fedora/data ]; then
		echo "fedora missing"
		exit
	fi

	sudo service tomcat7 stop

	echo Stopping tomcat7
	sleep 30

	echo restoring s3://${backups}/${backup}/fedora-data

	sudo chown -R ubuntu:ubuntu /usr/local/fedora/data

	${aws} s3 \
		sync s3://${backups}/${backup}/fedora-data/ /usr/local/fedora/data/ \
		--delete

	sudo chown -R tomcat7:tomcat7 /usr/local/fedora/data

	expect=/usr/bin/expect

	if [ ! -x ${expect} ]; then
		sudo apt-get -qq -y install expect
	fi

	echo 'spawn /usr/local/fedora/server/bin/fedora-rebuild.sh'  > rebuild
	echo 'expect "What do you want to do?*Enter (1-3) -->"'     >> rebuild
	echo 'send "1\r"'                                           >> rebuild
	echo 'expect "Start rebuilding?*Enter (1-2) -->"'           >> rebuild
	echo 'send "1\r"'                                           >> rebuild
	echo 'expect "objects rebuilt.*Finished."'                  >> rebuild
	echo '#interact'                                            >> rebuild

	sudo -E -u tomcat7 expect rebuild | grep -v "Adding object "
	echo

	echo 'spawn /usr/local/fedora/server/bin/fedora-rebuild.sh'  > rebuild
	echo 'expect "What do you want to do?*Enter (1-3) -->"'     >> rebuild
	echo 'send "2\r"'                                           >> rebuild
	echo 'expect "Start rebuilding?*Enter (1-2) -->"'           >> rebuild
	echo 'send "1\r"'                                           >> rebuild
	echo 'expect "objects rebuilt.*Finished."'                  >> rebuild
	echo '#interact'                                            >> rebuild

	sudo -E -u tomcat7 expect rebuild | grep -v "Adding object "
	echo

	rm rebuild

	sudo service tomcat7 start

	echo Sleeping ...
	sleep 60
fi

#
# Solr
#

solr_restore=0

if [ $solr_restore -eq 1 ]; then
	if [ ! -d /usr/local/solr/collection1 ]; then
		echo "solr missing"
		exit
	fi

	sudo service tomcat7 stop

	echo Stopping tomcat7
	sleep 30

	if [ -d /usr/local/solr/collection1/data ]; then
		sudo rm -rf /usr/local/solr/collection1/data/*
	fi

	sudo service tomcat7 start

	echo Starting tomcat7
	sleep 60

	./islandora718-reindex.php
fi

#
# Drupal
#

drupal_restore=1

if [ $drupal_restore -eq 1 ]; then
	source_db=drupal7.sql

	custom_modules='platform_content_types platform_main_feature dgi_ondemand islandora_accordion_rotator_module'

	custom_themes='chs_theme'

	if [ -f /etc/vsftpd.conf ]; then
		sudo chown -R ubuntu:ubuntu /var/www/html/sites
	fi

	${drush} pm-list --format=list|sort > /tmp/installed-modules.txt

	sudo service apache2 stop

	docroot=/var/www/html

	[ -f /tmp/${backup}.tar.gz ] && rm     /tmp/${backup}.tar.gz

	[ -d /tmp/${backup}        ] && rm -rf /tmp/${backup}

	${aws} s3 cp s3://${backups}/${backup}/enabled-modules.txt /tmp/enabled-modules.txt

	${aws} s3 cp s3://${backups}/${backup}/${backup}.tar.gz /tmp/${backup}.tar.gz 

	if [ -f /tmp/${backup}.tar.gz -a -f /tmp/enabled-modules.txt ]; then
		mkdir /tmp/${backup}
		tar xzf /tmp/${backup}.tar.gz -C /tmp/${backup}
		rm /tmp/${backup}.tar.gz

		${drush} -y sql-cli < /tmp/${backup}/${source_db} 2>/dev/null
#		${drush} -y sql-query "DELETE FROM cache_bootstrap WHERE cid='system_list';" 2>/dev/null
#		${drush} -y sql-query "UPDATE system SET status='0' WHERE name='memcache_admin';" 2>/dev/null
#		${drush} -y sql-query "UPDATE system SET status='0' WHERE name='memcache';" 2>/dev/null
#		sed -i '/^memcache_admin$/d'       /tmp/enabled-modules.txt
#		sed -i '/^memcache$/d'             /tmp/enabled-modules.txt
		echo

		sudo rsync -rlv --size-only --delete \
			--exclude sites/default/settings.php \
			--exclude sites/default/files/css/ \
			--exclude sites/default/files/js/ \
			/tmp/${backup}/drupal7/ \
			            ${docroot}/

#		for i in $custom_modules; do
#			sudo rsync -a --delete \
#				/tmp/${backup}/drupal7/sites/all/modules/$i/ \
#				            ${docroot}/sites/all/modules/$i/
#
#			find ${docroot}/sites/all/modules/$i -type f -exec chmod 644 {} \;
#			find ${docroot}/sites/all/modules/$i -type d -exec chmod 755 {} \;
#		done

#		for i in $custom_themes; do
#			sudo rsync -a --delete \
#				/tmp/${backup}/drupal7/sites/all/themes/$i/ \
#				            ${docroot}/sites/all/themes/$i/
#
#			find ${docroot}/sites/all/themes/$i -type f -exec chmod 644 {} \;
#			find ${docroot}/sites/all/themes/$i -type d -exec chmod 755 {} \;
#		done

#		sudo chown -R ubuntu:ubuntu ${docroot}
		sudo chown -R ubuntu:www-data ${docroot}

#		sudo rsync -a --delete \
#			/tmp/${backup}/drupal7/sites/default/files/ \
#			            ${docroot}/sites/default/files/

		sudo chown -R ubuntu:www-data ${docroot}/sites/default/files

		sudo chown    ubuntu:www-data ${docroot}/sites/default/settings.php

		enabled=`cat /tmp/enabled-modules.txt`

#		for i in $enabled; do
#			grep "^$i$" /tmp/installed-modules.txt > /dev/null
#			if [ $? -ne 0 ]; then
#				${drush} -y dl $i
#				echo
#			fi
#		done

		cat /tmp/enabled-modules.txt|sort                    > /tmp/a.txt
		${drush} pm-list --status=enabled --format=list|sort > /tmp/b.txt
		echo

		diff /tmp/a.txt /tmp/b.txt
		if [ $? -ne 0 ]; then
			echo "Failed to synchronize modules"
			exit
		fi

#		${drush} -y en git_deploy
#		echo

#		${drush} -y up
#		echo

#		${drush} -y en module_filter
#		echo

		${drush} -y vset islandora_base_url http://localhost:8080/fedora
		echo

		${drush} -y cc all
		echo

		sudo rsync -nrlv --size-only --delete \
			--exclude sites/default/settings.php \
			--exclude sites/default/files/css/ \
			--exclude sites/default/files/js/ \
			/tmp/${backup}/drupal7/ \
			            ${docroot}/
	fi

	if [ -f /etc/vsftpd.conf ]; then
		sudo chown -R ubuntu:www-data /var/www/html/sites
	fi

	sudo service apache2 start
fi
