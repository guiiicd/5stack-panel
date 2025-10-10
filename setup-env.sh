#!/bin/bash

if [ -n "$FIVE_STACK_ENV_SETUP" ]; then
    return;
fi

DEBUG=false
FIVE_STACK_ENV_SETUP=true
REVERSE_PROXY=""

# Load environment variables from .5stack-env.config if it exists
if [ -f .5stack-env.config ]; then
    source .5stack-env.config
fi

if [ -z "$KUBECONFIG" ]; then
    KUBECONFIG="/etc/rancher/k3s/k3s.yaml"
fi

if ! [ -f ./kustomize ] || ! [ -x ./kustomize ]
then
    echo "kustomize not found. Installing..."
    curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash
fi

while [[ $# -gt 0 ]]; do
    case $1 in
        --kubeconfig)
            KUBECONFIG="$2"
            shift 2
            ;;
        --debug)
            DEBUG=true
            shift
            ;;
        --reverse-proxy=*)
            REVERSE_PROXY="${1#*=}"
            if [ "$REVERSE_PROXY" = "0" ] || [ "$REVERSE_PROXY" = "n" ]; then
                REVERSE_PROXY=false
            else
                REVERSE_PROXY=true
            fi
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

if [ "$DEBUG" = true ]; then
    echo "Debug mode enabled (KUBECONFIG: $KUBECONFIG, REVERSE_PROXY: $REVERSE_PROXY)"
fi

ask_reverse_proxy() {
    while true; do
        read -p "Are you using a reverse proxy? (https://docs.5stack.gg/install/reverse-proxy) (y/n): " use_reverse_proxy
        if [ "$use_reverse_proxy" = "y" ] || [ "$use_reverse_proxy" = "n" ]; then
            break
        fi
        echo "Please enter 'y' or 'n'"
    done

    if [ "$use_reverse_proxy" = "y" ]; then
        REVERSE_PROXY=true
    else
        REVERSE_PROXY=false
    fi
}

update_env_var() {
    local file=$1
    local key=$2
    local value=$3
    
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s|^$key=.*|$key=$value|" "$file"
    else
        sed -i "s|^$key=.*|$key=$value|" "$file"
    fi
}

output_redirect() {
    if [ "$DEBUG" = true ]; then
        "$@"
    else
        "$@" >/dev/null
    fi
}

migrate_secrets_to_vault() {
    local secret_file=$1
    local vault_path=$2
    
    if [ ! -f "$secret_file" ]; then
        echo "Warning: $secret_file not found, skipping..."
        return
    fi
    
    # Read current file and migrate non-VAULT values
    while IFS='=' read -r key value || [ -n "$key" ]; do
        # Skip comments and empty lines
        if [[ $key =~ ^[[:space:]]*# ]] || [[ -z "$key" ]]; then
            continue
        fi
        
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)
        
        # Skip if already VAULT or empty
        if [ "$value" = "VAULT" ] || [ -z "$key" ] || [ -z "$value" ]; then
            continue
        fi

        echo "Migrating $key to Vault"
        
        # Upload to Vault
        local json_data=$(jq -n --arg k "$key" --arg v "$value" '{($k): $v}')
        echo "$json_data" | vault kv patch "$vault_path" -
        
        if [ $? -eq 0 ]; then
            echo "  ✓ Migrated $key to Vault"
            # Append to backup after successful upload
            echo "$key=$value" >> "${secret_file}.backup"
            # Update current file to VAULT
            if [[ "$OSTYPE" == "darwin"* ]]; then
                sed -i '' "s|^$key=.*|$key=VAULT|" "$secret_file"
            else
                sed -i "s|^$key=.*|$key=VAULT|" "$secret_file"
            fi
        else
            echo "  ✗ Failed to migrate $key to Vault"
        fi
    done < "$secret_file"
}

if [ -z "$REVERSE_PROXY" ]; then
    ask_reverse_proxy   
fi

if [ ! -f .5stack-env.config ]; then
    echo "Saving environment variables to .5stack-env.config";

    # Save environment variables to .5stack-env.config
    cat > .5stack-env.config << EOF
REVERSE_PROXY=$REVERSE_PROXY
KUBECONFIG=$KUBECONFIG
EOF
fi

if [ -d "base/secrets" ]; then
    echo "base/secrets directory found, moving to overlays/local-secrets"
    mv base/secrets/* overlays/local-secrets
    rm -rf base/secrets
fi

if [ -d "overlays/secrets" ]; then
    mv overlays/secrets/* overlays/local-secrets
    rm -rf overlays/secrets
fi

if [ -d "base/properties" ]; then
    echo "base/properties directory found, moving to overlays/config"
    mv base/properties/* overlays/config
    rm -rf base/properties
fi

for file in overlays/local-secrets/*.env.example; do
    env_file="${file%.example}"
    if [ ! -f "$env_file" ]; then
        cp "$file" "$env_file"
    fi
done

for file in overlays/config/*.env.example; do
    env_file="${file%.example}"
    if [ ! -f "$env_file" ]; then
        cp "$file" "$env_file"
    fi
done

# Replace $(RAND32) with a random base64 encoded string in all non-example env files
for env_file in overlays/local-secrets/*.env; do
    if [[ -f "$env_file" && ! "$env_file" == *.example ]]; then
        # Generate a random base64 encoded string
        random_string=$(openssl rand -base64 32 | tr '/' '_' | tr '=' '_')
        if [[ "$OSTYPE" == "darwin"* ]]; then
            sed -i '' "s/\$(RAND32)/$random_string/g" "$env_file"
        else
            sed -i "s/\$(RAND32)/$random_string/g" "$env_file"
        fi
    fi
done

POSTGRES_PASSWORD=$(grep "^POSTGRES_PASSWORD=" overlays/local-secrets/timescaledb-secrets.env | cut -d '=' -f2-)

if [ "$POSTGRES_PASSWORD" != "VAULT" ]; then
    POSTGRES_CONNECTION_STRING="postgres://hasura:$POSTGRES_PASSWORD@timescaledb:5432/hasura"
    if grep -q "^POSTGRES_CONNECTION_STRING=" overlays/local-secrets/timescaledb-secrets.env; then
        update_env_var "overlays/local-secrets/timescaledb-secrets.env" "POSTGRES_CONNECTION_STRING" "$POSTGRES_CONNECTION_STRING"
    else
        echo "" >> overlays/local-secrets/timescaledb-secrets.env
        echo "POSTGRES_CONNECTION_STRING=$POSTGRES_CONNECTION_STRING" >> overlays/local-secrets/timescaledb-secrets.env
    fi
fi

if [ -f "/var/lib/rancher/k3s/server/node-token" ]; then
    K3S_TOKEN=$(cat /var/lib/rancher/k3s/server/node-token)
fi

if [ -n "$K3S_TOKEN" ]; then
    if grep -q "^K3S_TOKEN=" overlays/local-secrets/api-secrets.env; then
        echo "K3S_TOKEN already set"
        update_env_var "overlays/local-secrets/api-secrets.env" "K3S_TOKEN" "$K3S_TOKEN"
    else
        echo "K3S_TOKEN not set, setting it"
        echo "K3S_TOKEN=$K3S_TOKEN" >> overlays/local-secrets/api-secrets.env
    fi
fi

# Using -h to suppress filename headers in grep output for Linux compatibility
WEB_DOMAIN=$(grep -h "^WEB_DOMAIN=" overlays/config/api-config.env | cut -d '=' -f2-)
WS_DOMAIN=$(grep -h "^WS_DOMAIN=" overlays/config/api-config.env | cut -d '=' -f2-)
API_DOMAIN=$(grep -h "^API_DOMAIN=" overlays/config/api-config.env | cut -d '=' -f2-)
DEMOS_DOMAIN=$(grep -h "^DEMOS_DOMAIN=" overlays/config/api-config.env | cut -d '=' -f2-)
MAIL_FROM=$(grep -h "^MAIL_FROM=" overlays/config/api-config.env | cut -d '=' -f2-)
S3_CONSOLE_HOST=$(grep -h "^S3_CONSOLE_HOST=" overlays/config/s3-config.env | cut -d '=' -f2-)
TYPESENSE_HOST=$(grep -h "^TYPESENSE_HOST=" overlays/config/typesense-config.env | cut -d '=' -f2-)

# Function to ask for a domain and update the config file
ask_and_update_domain() {
    local env_var_name=$1
    local file_path=$2
    local prompt_message=$3
    local current_value

    # Get the current value of the variable by using indirection
    eval "current_value=\$$env_var_name"

    if [ -z "$current_value" ]; then
        echo -e "\n\033[1;36m$prompt_message:\033[0m"
        read new_value
        while [ -z "$new_value" ]; do
            echo "This field cannot be empty. Please enter a value:"
            read new_value
        done
        # Update the variable in the script's environment
        eval "$env_var_name=\$new_value"
        # Update the variable in the config file
        update_env_var "$file_path" "$env_var_name" "$new_value"
    fi
}

# Ask for each domain individually if it's not set
ask_and_update_domain "WEB_DOMAIN" "overlays/config/api-config.env" "Enter your Web Domain (e.g., cs2.depizol.com.br)"
ask_and_update_domain "WS_DOMAIN" "overlays/config/api-config.env" "Enter your WebSocket Domain (e.g., wscs2.depizol.com.br)"
ask_and_update_domain "API_DOMAIN" "overlays/config/api-config.env" "Enter your API Domain (e.g., apics2.depizol.com.br)"
ask_and_update_domain "DEMOS_DOMAIN" "overlays/config/api-config.env" "Enter your Demos Domain (e.g., demoscs2.depizol.com.br)"
ask_and_update_domain "MAIL_FROM" "overlays/config/api-config.env" "Enter your Mail From address (e.g., contact@depizol.com.br)"
ask_and_update_domain "S3_CONSOLE_HOST" "overlays/config/s3-config.env" "Enter your S3 Console Host (e.g., s3cs2.depizol.com.br)"
ask_and_update_domain "TYPESENSE_HOST" "overlays/config/typesense-config.env" "Enter your Typesense Host (e.g., searchcs2.depizol.com.br)"


STEAM_WEB_API_KEY=$(grep -h "^STEAM_WEB_API_KEY=" overlays/local-secrets/steam-secrets.env | cut -d '=' -f2-)

while [ -z "$STEAM_WEB_API_KEY" ]; do
    echo "Please enter your Steam Web API key (required for Steam authentication). Get one at: https://steamcommunity.com/dev/apikey"
    read STEAM_WEB_API_KEY
done

update_env_var "overlays/local-secrets/steam-secrets.env" "STEAM_WEB_API_KEY" "$STEAM_WEB_API_KEY"

if [ "$VAULT_MANAGER" = true ]; then
    if ! command -v vault &> /dev/null; then
        echo "Error: vault CLI is not installed. Please install it first (https://developer.hashicorp.com/vault/install)."
        exit 1
    fi
    
    if ! vault status &> /dev/null; then
        echo "Error: Not logged into vault. Please run 'vault login' first"
        exit 1
    fi
    
    migrate_secrets_to_vault "overlays/local-secrets/api-secrets.env" "kv/api"
    migrate_secrets_to_vault "overlays/local-secrets/steam-secrets.env" "kv/steam"
    migrate_secrets_to_vault "overlays/local-secrets/timescaledb-secrets.env" "kv/timescaledb"
    migrate_secrets_to_vault "overlays/local-secrets/typesense-secrets.env" "kv/typesense"
    migrate_secrets_to_vault "overlays/local-secrets/tailscale-secrets.env" "kv/tailscale"
    migrate_secrets_to_vault "overlays/local-secrets/s3-secrets.env" "kv/s3"
    migrate_secrets_to_vault "overlays/local-secrets/redis-secrets.env" "kv/redis"
    migrate_secrets_to_vault "overlays/local-secrets/minio-secrets.env" "kv/minio"
    migrate_secrets_to_vault "overlays/local-secrets/hasura-secrets.env" "kv/hasura"
    migrate_secrets_to_vault "overlays/local-secrets/faceit-secrets.env" "kv/faceit"
    migrate_secrets_to_vault "overlays/local-secrets/discord-secrets.env" "kv/discord"
fi

echo "Domains and Hosts Configuration:"
echo "--------------------------------"
echo "WEB_DOMAIN: $WEB_DOMAIN"
echo "WS_DOMAIN: $WS_DOMAIN" 
echo "API_DOMAIN: $API_DOMAIN"
echo "DEMOS_DOMAIN: $DEMOS_DOMAIN"
echo "MAIL_FROM: $MAIL_FROM"
echo "S3_CONSOLE_HOST: $S3_CONSOLE_HOST"
echo "TYPESENSE_HOST: $TYPESENSE_HOST"
echo "--------------------------------"