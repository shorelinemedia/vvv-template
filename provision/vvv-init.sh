#!/usr/bin/env bash
# Provision WordPress Stable

# Quit out of the provisioner if something fails, like checking out htdocs
set -eo pipefail

vvv_output " "
vvv_output "\e[90m███████ \e[92m██   ██ \e[35m ██████  \e[91m██████  \e[34m███████ \e[95m██      \e[94m██ \e[90m███    ██ \e[94m███████\e[0m "
vvv_output "\e[90m██      \e[92m██   ██ \e[35m██    ██ \e[91m██   ██ \e[34m██      \e[95m██      \e[94m██ \e[90m████   ██ \e[94m██      \e[0m"
vvv_output "\e[90m███████ \e[92m███████ \e[35m██    ██ \e[91m██████  \e[34m█████   \e[95m██      \e[94m██ \e[90m██ ██  ██ \e[94m█████ \e[0m"
vvv_output "\e[90m     ██ \e[92m██   ██ \e[35m██    ██ \e[91m██   ██ \e[34m██      \e[95m██      \e[94m██ \e[90m██  ██ ██ \e[94m██    \e[0m"
vvv_output "\e[90m███████ \e[92m██   ██ \e[35m ██████  \e[91m██   ██ \e[34m███████ \e[95m███████ \e[94m██ \e[90m██   ████ \e[94m███████\e[0m" 
vvv_output "\e[92m--- Provisioning ${VVV_SITE_NAME} ---\e[0m"
vvv_output " "

echo " * Custom site template provisioner ${VVV_SITE_NAME} - downloads and installs a copy of WP stable for testing, building client sites, etc"

# fetch the first host as the primary domain. If none is available, generate a default using the site name
DB_NAME=$(get_config_value 'db_name' "${VVV_SITE_NAME}")
DB_NAME=${DB_NAME//[\\\/\.\<\>\:\"\'\|\?\!\*]/}
DB_PREFIX=$(get_config_value 'db_prefix' 'wp_')
DOMAIN=$(get_primary_host "${VVV_SITE_NAME}".test)
PUBLIC_DIR=$(get_config_value 'public_dir' "public_html")
if [[ ! "$PUBLIC_DIR" =~ ^"/" ]]; then
  PUBLIC_DIR="/${PUBLIC_DIR}"
fi
SITE_TITLE=$(get_config_value 'site_title' "${DOMAIN}")
WP_LOCALE=$(get_config_value 'locale' 'en_US')
WP_TYPE=$(get_config_value 'wp_type' "single")
WP_VERSION=$(get_config_value 'wp_version' 'latest')

PUBLIC_DIR_PATH="${VVV_PATH_TO_SITE%/}"
if [ ! -z "${PUBLIC_DIR}" ]; then
  PUBLIC_DIR_PATH="${PUBLIC_DIR_PATH}${PUBLIC_DIR}"
fi

HTDOCS_REPO=$(get_config_value 'htdocs' '')

# @description Make a database, if we don't already have one
function setup_database() {
  echo -e " * Creating database '${DB_NAME}' (if it's not already there)"
  mysql -u root --password=root -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`"
  echo -e " * Granting the wp user priviledges to the '${DB_NAME}' database"
  mysql -u root --password=root -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO wp@localhost IDENTIFIED BY 'wp';"
  echo -e " * DB operations done."
}

function setup_nginx_folders() {
  echo " * Setting up the log subfolder for Nginx logs"
  noroot mkdir -p "${VVV_PATH_TO_SITE%/}/log"
  noroot touch "${VVV_PATH_TO_SITE%/}/log/nginx-error.log"
  noroot touch "${VVV_PATH_TO_SITE%/}/log/nginx-access.log"
}

function setup_public_dir() {
  echo " * Creating the public folder at '${PUBLIC_DIR}' if it doesn't exist already"
  noroot mkdir -p "${PUBLIC_DIR_PATH}"
}

# @description Takes a string and replaces all instances of a token with a value
function vvv_site_template_search_replace() {
  local content="$1"
  local token="$2"
  local value="$3"

  # Read the file contents and replace the token with the value
  content=${content//$token/$value}
  echo "${content}"
}
export -f vvv_site_template_search_replace

# @description Takes a file, and replaces all instances of a token with a value
function vvv_site_template_search_replace_in_file() {
  local file="$1"

  # Read the file contents and replace the token with the value
  local content
  if [[ -f "${file}" ]]; then
    content=$(<"${file}")
    vvv_site_template_search_replace "${content}" "${2}" "${3}"
  else
    return 1
  fi
}
export -f vvv_site_template_search_replace_in_file

function install_plugins() {
  WP_PLUGINS=$(get_config_value 'install_plugins' '')
  if [ ! -z "${WP_PLUGINS}" ]; then
    isurl='(https?|ftp|file)://[-A-Za-z0-9\+&@#/%?=~_|!:,.;]*[-A-Za-z0-9\+&@#/%=~_|]'
    for plugin in ${WP_PLUGINS//- /$'\n'}; do
      if [[ "${plugin}" =~ $isurl ]]; then
        echo " ! Warning, a URL was found for this plugin, attempting install and activate with --force set for ${plugin}"
        noroot wp plugin install "${plugin}" --activate --force
      else
        if noroot wp plugin is-installed "${plugin}"; then
          echo " * The ${plugin} plugin is already installed."
        else
          echo " * Installing and activating plugin: '${plugin}'"
          noroot wp plugin install "${plugin}" --activate
        fi
      fi
    done
  fi
}

function install_themes() {
  WP_THEMES=$(get_config_value 'install_themes' '')
  if [ ! -z "${WP_THEMES}" ]; then
      isurl='(https?|ftp|file)://[-A-Za-z0-9\+&@#/%?=~_|!:,.;]*[-A-Za-z0-9\+&@#/%=~_|]'
      for theme in ${WP_THEMES//- /$'\n'}; do
        if [[ "${theme}" =~ $isurl ]]; then
          echo " ! Warning, a URL was found for this theme, attempting install of ${theme} with --force set"
          noroot wp theme install --force "${theme}"
        else
          if noroot wp theme is-installed "${theme}"; then
            echo " * The ${theme} theme is already installed."
          else
            echo " * Installing theme: '${theme}'"
            noroot wp theme install "${theme}"
          fi
        fi
      done
  fi
}

function copy_nginx_configs() {
  echo " * Copying the sites Nginx config template"

  local NCONFIG

  if [ -f "${VVV_PATH_TO_SITE%/}/provision/vvv-nginx-custom.conf" ]; then
    echo " * A vvv-nginx-custom.conf file was found"
    NCONFIG=$(vvv_site_template_search_replace_in_file "${VVV_PATH_TO_SITE%/}/provision/vvv-nginx-custom.conf" "{vvv_public_dir}" "${PUBLIC_DIR}")
  else
    echo " * Using the default vvv-nginx-default.conf, to customize, create a vvv-nginx-custom.conf"
    NCONFIG=$(vvv_site_template_search_replace_in_file "${VVV_PATH_TO_SITE%/}/provision/vvv-nginx-default.conf" "{vvv_public_dir}" "${PUBLIC_DIR}")
  fi

  LIVE_URL=$(get_config_value 'live_url' '')
  if [ ! -z "$LIVE_URL" ]; then
    echo " * Adding support for Live URL redirects to NGINX of the website's media"
    # replace potential protocols, and remove trailing slashes
    LIVE_URL=$(echo "${LIVE_URL}" | sed 's|https://||' | sed 's|http://||'  | sed 's:/*$::')

    redirect_config=$((cat <<END_HEREDOC
if (!-e \$request_filename) {
  rewrite ^/[_0-9a-zA-Z-]+(/wp-content/uploads/.*) \$1;
}
if (!-e \$request_filename) {
  rewrite ^/wp-content/uploads/(.*)\$ \$scheme://${LIVE_URL}/wp-content/uploads/\$1 redirect;
}
END_HEREDOC

    )
    )

    NCONFIG=$(vvv_site_template_search_replace "${NCONFIG}" "{{LIVE_URL}}" "${redirect_config}")
  else
    NCONFIG=$(vvv_site_template_search_replace "${NCONFIG}" "{{LIVE_URL}}" "")
  fi

  NCONFIG=$(vvv_site_template_search_replace "${NCONFIG}" "{{PUBLIC_DIR_PATH}}" "${PUBLIC_DIR_PATH}")

  # Write out the new Nginx file for VVV to pick up.
  noroot touch  "${VVV_PATH_TO_SITE%/}/provision/vvv-nginx.conf"
  echo "${NCONFIG}" > "${VVV_PATH_TO_SITE%/}/provision/vvv-nginx.conf"
}

function setup_wp_config_constants() {
  set +e
  noroot shyaml get-values-0 -q "sites.${VVV_SITE_NAME}.custom.wpconfig_constants" < "${VVV_CONFIG}" |
  while IFS='' read -r -d '' key &&
        IFS='' read -r -d '' value; do
      lower_value=$(echo "${value}" | awk '{print tolower($0)}')
      echo " * Adding constant '${key}' with value '${value}' to wp-config.php"
      if [ "${lower_value}" == "true" ] || [ "${lower_value}" == "false" ] || [[ "${lower_value}" =~ ^[+-]?[0-9]*$ ]] || [[ "${lower_value}" =~ ^[+-]?[0-9]+\.?[0-9]*$ ]]; then
        noroot wp config set "${key}" "${value}" --raw
      else
        noroot wp config set "${key}" "${value}"
      fi
  done
  set -e
}

function restore_db_backup() {
  echo " * Found a database backup at ${1}. Restoring the site"
  noroot wp config set DB_USER "wp"
  noroot wp config set DB_PASSWORD "wp"
  noroot wp config set DB_HOST "localhost"
  noroot wp config set DB_NAME "${DB_NAME}"
  noroot wp config set table_prefix "${DB_PREFIX}"
  noroot wp db import "${1}"
  echo " * Installed database backup"
}

# @description Downloads WordPress given a locale and version.
function download_wordpress() {
  echo " * Downloading WordPress version '${1}' locale: '${2}'"
  noroot wp core download --locale="${2}" --version="${1}"
}

function initial_wpconfig() {
  echo " * Setting up wp-config.php"
  noroot wp config create --dbname="${DB_NAME}" --dbprefix="${DB_PREFIX}" --dbuser=wp --dbpass=wp --extra-php <<PHP
@ini_set( 'display_errors', 0 );
PHP
  noroot wp config set WP_DEBUG true --raw
  noroot wp config set WP_DEBUG_LOG true --raw
  noroot wp config set WP_DEBUG_DISPLAY false --raw
  noroot wp config set WP_DISABLE_FATAL_ERROR_HANDLER true --raw
  noroot wp config set SCRIPT_DEBUG true --raw
  noroot wp config set JETPACK_DEV_DEBUG true --raw
  noroot wp config set WP_ENVIRONMENT_TYPE 'development'
  noroot wp config set WP_LOCAL_DEV true --raw
  noroot wp config set WP_ENV 'development'
  noroot wp config set DISALLOW_FILE_EDIT true --raw
  noroot wp config set DONOTCACHEPAGE true --raw
  noroot wp config set DONOTROCKETOPTIMIZE true --raw
  noroot wp config set WPMS_ON true --raw
  noroot wp config set WPMS_MAILER 'smtp'
  noroot wp config set WPMS_SMTP_HOST 'vvv.test'
  noroot wp config set WPMS_SMTP_PORT '1025'
  noroot wp config set WPMS_SMTP_AUTH false --raw
  noroot wp config set WPMS_SMTP_AUTOTLS false --raw
  noroot wp config set WPMS_SSL ''
  noroot wp config set WPMS_SMTP_USER ''
  noroot wp config set WPMS_SMTP_PASS ''
  noroot wp config set MWP_SKIP_BOOTSTRAP true --raw
  noroot wp config set WPCF7_ADMIN_READ_CAPABILITY 'manage_options'
  noroot wp config set WPCF7_ADMIN_READ_WRITE_CAPABILITY 'manage_options'
  noroot wp config set SHORELINE_SEO_SKIP_SQL_DELETE true --raw
}

function maybe_import_test_content() {
  INSTALL_TEST_CONTENT=$(get_config_value 'install_test_content' "")
  if [ ! -z "${INSTALL_TEST_CONTENT}" ]; then
    echo " * Downloading test content from github.com/poststatus/wptest/master/wptest.xml"
    noroot curl -s https://raw.githubusercontent.com/poststatus/wptest/master/wptest.xml > /tmp/import.xml
    echo " * Installing the wordpress-importer"
    noroot wp plugin install wordpress-importer
    echo " * Activating the wordpress-importer"
    noroot wp plugin activate wordpress-importer
    echo " * Importing test data"
    noroot wp import /tmp/import.xml --authors=create
    echo " * Cleaning up import.xml"
    rm /tmp/import.xml
    echo " * Test content installed"
  fi
}

function install_wp() {
  echo " * Installing WordPress"
  ADMIN_USER=$(get_config_value 'admin_user' "shoreline-admin")
  ADMIN_PASSWORD=$(get_config_value 'admin_password' "password")
  ADMIN_EMAIL=$(get_config_value 'admin_email' "team@shoreline.media")

  echo " * Installing using wp core install --url=\"${DOMAIN}\" --title=\"${SITE_TITLE}\" --admin_name=\"${ADMIN_USER}\" --admin_email=\"${ADMIN_EMAIL}\" --admin_password=\"${ADMIN_PASSWORD}\""
  noroot wp core install --url="${DOMAIN}" --title="${SITE_TITLE}" --admin_name="${ADMIN_USER}" --admin_email="${ADMIN_EMAIL}" --admin_password="${ADMIN_PASSWORD}"
  echo " * WordPress was installed, with the username '${ADMIN_USER}', and the password '${ADMIN_PASSWORD}' at '${ADMIN_EMAIL}'"

  if [ "${WP_TYPE}" = "subdomain" ]; then
    echo " * Running Multisite install using wp core multisite-install --subdomains --url=\"${DOMAIN}\" --title=\"${SITE_TITLE}\" --admin_name=\"${ADMIN_USER}\" --admin_email=\"${ADMIN_EMAIL}\" --admin_password=\"${ADMIN_PASSWORD}\""
    noroot wp core multisite-install --subdomains --url="${DOMAIN}" --title="${SITE_TITLE}" --admin_name="${ADMIN_USER}" --admin_email="${ADMIN_EMAIL}" --admin_password="${ADMIN_PASSWORD}"
    echo " * Multisite install complete"
  elif [ "${WP_TYPE}" = "subdirectory" ]; then
    echo " * Running Multisite install using wp core ${INSTALL_COMMAND} --url=\"${DOMAIN}\" --title=\"${SITE_TITLE}\" --admin_name=\"${ADMIN_USER}\" --admin_email=\"${ADMIN_EMAIL}\" --admin_password=\"${ADMIN_PASSWORD}\""
    noroot wp core multisite-install --url="${DOMAIN}" --title="${SITE_TITLE}" --admin_name="${ADMIN_USER}" --admin_email="${ADMIN_EMAIL}" --admin_password="${ADMIN_PASSWORD}"
    echo " * Multisite install complete"
  fi

  DELETE_DEFAULT_PLUGINS=$(get_config_value 'delete_default_plugins' '')
  if [ ! -z "${DELETE_DEFAULT_PLUGINS}" ]; then
    echo " * Deleting the default plugins akismet and hello dolly"
    noroot wp plugin delete akismet
    noroot wp plugin delete hello
  fi

  maybe_import_test_content
}

function update_wp() {
  if [[ $(noroot wp core version) > "${WP_VERSION}" ]]; then
    echo " * Installing an older version '${WP_VERSION}' of WordPress"
    noroot wp core update --version="${WP_VERSION}" --force
  else
    echo " * Updating WordPress '${WP_VERSION}'"
    noroot wp core update --version="${WP_VERSION}"
  fi
}

# @description Setup a wp-cli.yml config for easier SSH, replacing any existing WP CLI config.
# @noargs
function setup_cli() {
  rm -f "${VVV_PATH_TO_SITE%/}/wp-cli.yml"
  echo "# auto-generated file" > "${VVV_PATH_TO_SITE%/}/wp-cli.yml"
  echo "path: \"${PUBLIC_DIR_PATH}\"" >> "${VVV_PATH_TO_SITE%/}/wp-cli.yml"
  echo "\"@vvv\":" >> "${VVV_PATH_TO_SITE%/}/wp-cli.yml"
  echo "  ssh: vagrant" >> "${VVV_PATH_TO_SITE%/}/wp-cli.yml"
  echo "  path: ${PUBLIC_DIR_PATH}" >> "${VVV_PATH_TO_SITE%/}/wp-cli.yml"
  echo "\"@${VVV_SITE_NAME}\":" >> "${VVV_PATH_TO_SITE%/}/wp-cli.yml"
  echo "  ssh: vagrant" >> "${VVV_PATH_TO_SITE%/}/wp-cli.yml"
  echo "  path: ${PUBLIC_DIR_PATH}" >> "${VVV_PATH_TO_SITE%/}/wp-cli.yml"
}

# @description Configure SSH Key permissions
function configure_keys() {
  # Update permissions for SSH Keys
  if [ -f "/home/vagrant/.ssh/id_rsa" ]; then
    chmod 600 /home/vagrant/.ssh/id_rsa
  fi
  if [ -f "/home/vagrant/.ssh/id_rsa.pub" ]; then
    chmod 644 /home/vagrant/.ssh/id_rsa.pub
  fi
}

# @description Install liquid prompt for pretty command line formatting
function install_liquidprompt() {
  noroot mkdir /home/vagrant/liquidprompt
  noroot git clone https://github.com/nojhan/liquidprompt.git /home/vagrant/liquidprompt
  source /home/vagrant/liquidprompt/liquidprompt

  # Copy liquidprompt config
  noroot cp /home/vagrant/liquidprompt/liquidpromptrc-dist /home/vagrant/.config/liquidpromptrc

  # Add to .bashrc
  noroot cat <<- "EOF" >> /home/vagrant/.bashrc

# Only load Liquid Prompt in interactive shells, not from a script or from scp
[[ $- = *i* ]] && source /home/vagrant/liquidprompt/liquidprompt

EOF

  # Update settings in config
  PATHLENGTH=16
  sed "s/LP_PATH_LENGTH\=[0-9]*/LP_PATH_LENGTH=${PATHLENGTH}/" /home/vagrant/.config/liquidpromptrc
}

# Install yarn as a new alternative to npm
function install_yarn() {
  curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | sudo apt-key add -
  echo "deb https://dl.yarnpkg.com/debian/ stable main" | sudo tee /etc/apt/sources.list.d/yarn.list

  sudo apt update
  sudo apt install --no-install-recommends yarn
}

# Install gulp
function yarn_global() {
  echo "---Installing gulp for dependency management & dev tools---"
  yarn global add gulp-cli
}

# Checkout HTDOCS repo
function checkout_htdocs_repo() {
  if [[ ! -z "$HTDOCS_REPO" ]]; then

    # Only checkout GIT repo on initial provision
    if [[ ! -f "${PUBLIC_DIR_PATH}/wp-load.php" ]]; then
      cd "${PUBLIC_DIR_PATH}"


      # Setup our WPEngine starter project in the folder before it's created
      echo "Checking out project from ${HTDOCS_REPO} to ${PUBLIC_DIR_PATH}"


      # Create git repository, add origin remote and do first pull
      echo "Initializing git repo"
      noroot git init
      echo "Adding git remote"
      noroot git remote add origin "${HTDOCS_REPO}"
      echo "Pulling master branch from ${HTDOCS_REPO}"
      noroot git pull --recurse-submodules origin master --force
      cd ${VVV_PATH_TO_SITE}
    fi

  fi
}

function replace_custom_provision_scripts() {
  # Copy conf file with curly brace placeholders to actual file not controlled by git
  cp -f "${VVV_PATH_TO_SITE}/provision/.update-local.sh.conf" "${VVV_PATH_TO_SITE}/provision/update-local.sh"

  # Replace the {curly_brace_placeholder} text with info from vvv config
  sed -i "s#{vvv_primary_domain}#${DOMAIN}#" "${VVV_PATH_TO_SITE}/provision/update-local.sh"
  sed -i "s#{vvv_site_name}#${VVV_SITE_NAME}#" "${VVV_PATH_TO_SITE}/provision/update-local.sh"
  sed -i "s#{vvv_path_to_site}#${VVV_PATH_TO_SITE}#" "${VVV_PATH_TO_SITE}/provision/update-local.sh"
}

function create_sql_directory() {
  if [[ ! -d "${PUBLIC_DIR_PATH}/wp-content/database-backups" ]]; then
    noroot mkdir -p "${PUBLIC_DIR_PATH}/wp-content/database-backups"
  fi
}

# initial working directory
cd "${VVV_PATH_TO_SITE}"

setup_database
setup_nginx_folders
setup_public_dir
setup_cli

# Run this before VVV does it's normal WP installation check so we can clone
# the specified repo into a clean directory without any other files being 
# placed there first
checkout_htdocs_repo

# Start working inside WP public_dir
cd "${PUBLIC_DIR_PATH}"

if [ "${WP_TYPE}" == "none" ]; then
  echo " * wp_type was set to none, provisioning WP was skipped, moving to Nginx configs"
else
  echo " * Install type is '${WP_TYPE}'"

  # Install and configure the latest stable version of WordPress
  if [[ ! -f "${PUBLIC_DIR_PATH}/wp-load.php" ]]; then
    download_wordpress "${WP_VERSION}" "${WP_LOCALE}"
  fi

  if [[ ! -f "${PUBLIC_DIR_PATH}/wp-config.php" ]]; then
    initial_wpconfig
  fi

  if ! $(noroot wp core is-installed ); then
    echo " * WordPress is present but isn't installed to the database, checking for SQL dumps in wp-content/database.sql or the main backup folder."
    if [ -f "${PUBLIC_DIR_PATH}/wp-content/database.sql" ]; then
      restore_db_backup "${PUBLIC_DIR_PATH}/wp-content/database.sql"
    elif [ -f "/srv/database/backups/${VVV_SITE_NAME}.sql" ]; then
      restore_db_backup "/srv/database/backups/${VVV_SITE_NAME}.sql"
    else
      install_wp
    fi
  else
    update_wp
  fi
fi

copy_nginx_configs
setup_wp_config_constants

# Install Liquidprompt on first provision only
if [[ ! -d "/home/vagrant/liquidprompt" ]]; then
  install_liquidprompt
fi
install_yarn
yarn_global
configure_keys
replace_custom_provision_scripts
install_plugins
install_themes
create_sql_directory

echo " * Site Template provisioner script completed for ${VVV_SITE_NAME}"