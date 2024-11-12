#!/bin/bash
# Author: Michele Loriso
# Version: v1.0.0
# Date: 11-2024
# Description: Auto-deployer for Django 5
# Usage: ./deploy.sh after logging in to the server (VPS)
# DEPLOY IN MINUTES!

# GLOBAL VARIABLES
DOMAIN_NAME=""
USER_NAME=""
DB_NAME=""
DB_PASSWORD=""
VENV_NAME=""
PROJECT_PATH=""
DJANGO_PROJECT_NAME=""

# FUNCTIONS SECTION
add_swap_file() {
	echo "Verify the existance of a swap file, please:"; echo
	free -h
	echo; echo "Verify if there is enough free space:"; echo
	df -h;
	echo
	while [ 1 ]
	do
		read -p "Do you need a swap file in your machine? (y/n) " swap_requested
		if [[ $swap_requested == "y" ]]; then
			sudo fallocate -l 1G /swapfile
			sudo chmod 600 /swapfile
			sudo mkswap /swapfile
			sudo swapon /swapfile
			sudo cp /etc/fstab /etc/fstab.bak
			echo "/swapfile none swap sw 0 0" | sudo tee -a /etc/fstab
			sudo sysctl vm.swappiness=10
			echo "vm.swappiness=10" >> /etc/sysctl.conf
			sudo sysctl vm.vfs_cache_pressure=50
			echo "vm.vfs_cache_pressure=50" >> /etc/sysctl.conf
		break
		elif [[ $swap_requested == "n" ]]; then
			echo "Okay, let's move on..."; echo
		break
		else
			echo "Please, enter a valid response."
		fi
	done
}

add_folders() {
	while [ 1 ]; do
		read -p "What's your name? " USER_NAME
		if [[ $USER_NAME ]]; then
			PROJECT_PATH="/opt/${USER_NAME}_project_directory"
			VENV_NAME="${USER_NAME}_env"
			echo "Creating folders in /opt/..."
			sudo mkdir -p "$PROJECT_PATH"
			echo "Directories successfully created!"; echo
			break
		else
			echo "Please, provide a non null name."
		fi
	done
}

add_firewall() {
	echo "Setting up the firewall..."
	echo
	if ! command -v ufw &> /dev/null; then
		echo "UFW is not installed. Proceeding to install it!"
		echo;
		if command -v apt &> /dev/null; then
			sudo apt update
			sudo apt install ufw -y
		elif command -v dnf &> /dev/null; then
			sudo dnf install ufw -y
		elif command -v pacman &> /dev/null; then
		        sudo pacman -S ufw --noconfirm
	    	else
        		echo "Unsupported package manager. Please install UFW manually."
        		exit 1
    		fi
    	echo "UFW installed successfully."
	fi
	if ! command -v sshd &> /dev/null; then
    		echo "OpenSSH server is not installed. Installing OpenSSH server..."
    		echo
		if command -v apt &> /dev/null; then
        		sudo apt install openssh-server -y
    		elif command -v dnf &> /dev/null; then
        		sudo dnf install openssh-server -y
    		elif command -v pacman &> /dev/null; then
        		sudo pacman -S openssh --noconfirm
    		else
        		echo "Unsupported package manager. Please install OpenSSH manually."
        		exit 1
    		fi
    		sudo systemctl start sshd
    		sudo systemctl enable sshd
    		echo "OpenSSH server installed and started successfully!"
	else
    		echo "OpenSSH server is already installed."
	fi
	ufw allow OpenSSH
	ufw enable
}

add_database() {
	DB_NAME="${USER_NAME}_DB"
	echo "Creating and configuring a PostgreSQL database..."; echo
	while [ 1 ]; do
		read -p "Please, choose (and take note of!) a password for your database: " DB_PASSWORD
		if [[ $DB_PASSWORD ]]; then
			sudo -u postgres psql << EOF
			CREATE DATABASE "$DB_NAME";
			\c "$DB_NAME"
			CREATE USER "$USER_NAME" WITH PASSWORD "$DB_PASSWORD";
			ALTER ROLE "$USER_NAME" SET client_encoding TO 'utf8';
			ALTER ROLE "$USER_NAME" SET default_transaction_isolation TO 'read committed';
			ALTER ROLE "$USER_NAME" SET timezone TO 'UTC';
			GRANT ALL PRIVILEGES ON DATABASE "$DB_NAME" TO "$USER_NAME";
			\q
			EOF
			break
		else
			echo "Please, insert a valid password."
		fi
	done
	echo "PostgreSQL database created with success!"; echo	
}

create_gunicorn_socket() {
    local socket_file="/etc/systemd/system/gunicorn.socket"
    sudo tee "$socket_file" > /dev/null << EOF
[Unit]
Description=gunicorn socket

[Socket]
ListenStream=/run/gunicorn.sock

[Install]
WantedBy=sockets.target
EOF
}

create_gunicorn_service() {
	local service_file="/etc/systemd/system/gunicorn.service"
	sudo tee "$service_file" > /dev/null << EOF
[Unit]
Description=gunicorn daemon
Requires=gunicorn.socket
After=network.target

[Service]
User=root
WorkingDirectory=${PROJECT_PATH}
ExecStart=${PROJECT_PATH}/${VENV_NAME}/bin/gunicorn \
          --access-logfile - \
          --workers 3 \
          --bind unix:/run/gunicorn.sock \
          ${DJANGO_PROJECT_NAME}.wsgi:application

[Install]
WantedBy=multi-user.target
EOF

}

setting_nginx() {
	read -p "Please, enter your domain (e.g., example.com): " DOMAIN_NAME
	local file="/etc/nginx/sites-available/$DJANGO_PROJECT_NAME"
	sudo tee "$file" > /dev/null << EOF
server {
	server_name ${DOMAIN_NAME} www.${DOMAIN_NAME};
    	client_max_body_size 50M;
    	location = /favicon.ico { access_log off; log_not_found off; }
	location /static/ {
        	alias ${PROJECT_PATH}/staticfiles;
    	}
	location /media/ {
		alias ${PROJECT_PATH}/media;
	}
    	location / {
        	include proxy_params;
        	proxy_pass http://unix:/run/gunicorn.sock;
    	}
}
EOF
}

add_django_project() {
while [ 1 ]
do
	read -p "What's your Django project's name? Please, don't mispell. " DJANGO_PROJECT_NAME
	if [[ $DJANGO_PROJECT_NAME ]]; then
		break
	else
		echo "Please, provide a non null name."
	fi
done
django-admin startproject "$DJANGO_PROJECT_NAME" "$PROJECT_PATH"
}

# MAIN
clear; echo "Welcome in this Django deployment utility!"
echo "This is a fully automated procedure... Just relax and feed in your data."; echo
# ADD FOLDERS
clear
add_folders
# FIREWALL SETTINGS 
add_firewall
# SWAP FILE SECTION
add_swap_file
# INSTALLING DEPENDENCIES
sudo apt update
sudo apt install python3-venv python3-dev libpq-dev postgresql postgresql-contrib nginx curl
# DATABASE SETTINGS
echo
add_database
# CONFIGURING VENV
cd "$PROJECT_PATH"
echo "Starting python3 virtual environment $VENV_NAME..."
python3 -m venv $VENV_NAME
source "${VENV_NAME}/bin/activate"
echo "Installing minimum dependencies... Please, wait."
pip install django gunicorn psycopg2-binary
# STARTING A NEW EMPTY DJANGO PROJECT
add_django_project
# WAITING FOR THE FILES TO BE UPLOADED VIA FTP
echo "Now you can upload via FTP your Django project folder in ${PROJECT_PATH}, then press ENTER..."
echo "Please, be AWARE OF THE FOLLOWING:"; echo
echo "1) Your manage.py and requirements.txt files should be in ${PROJECT_PATH}!"; echo
echo "2) Locate ALLOWED_HOSTS list in your setting.py file and append proper strings ->"; echo
echo -e "\tALLOWED_HOSTS = [\"yourdomain.com\", \"IP_ADDRESS\", \"localhost\"]";echo
echo "3) DEBUG should be set to FALSE";echo
echo "4) Locate DATABASES in your settings.py file and check (and correct) data ->"; echo
echo -e "\tDATABASES = {"; echo -e "\t\t'default': {"
echo -e "\t\t\t'ENGINE': 'django.db.backends.postgresql',"
echo -e "\t\t\t'NAME': '${DB_NAME}',"
echo -e "\t\t\t'USER': '${USER_NAME}',"
echo -e "\t\t\t'PASSWORD': '${DB_PASSWORD}',"
echo -e "\t\t\t'HOST': 'localhost',"
echo -e "\t\t\t'PORT': '',"; echo -e "\t}"; echo "}";echo
echo "5) Check for: STATIC_URL = '/static/' and MEDIA_URL = '/media/'"; echo
echo "6) Set: STATIC_ROOT = BASE_DIR / 'staticfiles/' and MEDIA_ROOT = BASE_DIR / 'media'"; echo
echo "7) Set DEFAULT_AUTO_FIELD = 'django.db.models.BigAutoField'"; echo
read
# INSTALLING DEPENDENCIES IN requirements.txt
cd ~/"$PROJECT_PATH"
if [[ -f requirements.txt ]]; then
	pip install -r requirements.txt
	echo "Installing dependencies from requirements.txt..."
else
	echo "File requirements.txt not found."
fi
# MIGRATING THE DATABASE
echo "Preparing for migrating the database..."
python3 manage.py makemigrations
python3 manage.py migrate
echo "Migrations done!"
# CREATING A SUPERUSER AND COLLECTING STATIC FILES
python3 manage.py createsuperuser
python3 manage.py collectstatic
# GUNICORN SETTINGS
sudo ufw allow 8000
gunicorn --bind 0.0.0.0:8000 ${DJANGO_PROJECT_NAME}.wsgi
deactivate
create_gunicorn_socket
create_gunicorn_service
sudo systemctl start gunicorn.socket
sudo systemctl enable gunicorn.socket
echo "Checking if Gunicorn works correctly... Remember to exit the screen by pressing 'q'"; echo
sudo systemctl status gunicorn.socket
sudo systemctl status gunicorn
# NGINX SETTINGS
setting_nginx
sudo ln -s "/etc/nginx/sites-available/$DJANGO_PROJECT_NAME" /etc/nginx/sites-enabled
sudo systemctl restart nginx
if sudo ufw status | grep -q "8000"; then
    sudo ufw delete allow 8000
fi
sudo ufw allow 'Nginx Full'
# CERTBOT SETTINGS
echo "Installing Certbot..."
sudo snap install core; sudo snap refresh core
sudo apt remove certbot
sudo snap install --classic certbot
sudo ln -s /snap/bin/certbot /usr/bin/certbot
sudo certbot --nginx -d $DOMAIN_NAME -d "www.$DOMAIN_NAME"
sudo systemctl status snap.certbot.renew.service
sudo certbot renew --dry-run
