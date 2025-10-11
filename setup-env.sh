#!/bin/bash

# Evita que o script seja carregado várias vezes
if [ -n "$FIVE_STACK_ENV_SETUP" ]; then
    return;
fi

CONFIG_FILE=".5stack-domain-choice"
DOMAIN_CHOICE=""

# Função para perguntar ao usuário a sua escolha de domínio
ask_domain_choice() {
    while true; do
        read -p "Your domain will be with or without subdomain? (with/without): " choice
        if [ "$choice" = "with" ] || [ "$choice" = "without" ]; then
            echo "$choice" > "$CONFIG_FILE"
            DOMAIN_CHOICE=$choice
            break
        fi
        echo "Please enter 'with' or 'without'"
    done
}

# Verifica se a escolha já foi feita e salva
if [ -f "$CONFIG_FILE" ]; then
    DOMAIN_CHOICE=$(cat "$CONFIG_FILE")
else
    # Se não, pergunta ao usuário e salva a escolha
    ask_domain_choice
fi

# Carrega o script de setup apropriado com base na escolha
if [ "$DOMAIN_CHOICE" = "with" ]; then
    if [ -f "setup-env-subdomain.sh" ]; then
        source setup-env-subdomain.sh "$@"
    else
        echo "Error: setup-env-subdomain.sh not found."
        exit 1
    fi
else
    if [ -f "setup-env-no-subdomain.sh" ]; then
        source setup-env-no-subdomain.sh "$@"
    else
        echo "Error: setup-env-no-subdomain.sh not found."
        exit 1
    fi
fi