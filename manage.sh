#!/bin/bash

# Configuration
INFRA_DIR="$HOME/sinapis-infra"
APPS=("diamond-inventory" "another-app") # Add new apps here

function restart_all() {
    echo "Stopping all applications..."
    for app in "${APPS[@]}"; do
        if [ -d "$HOME/$app" ]; then
            cd "$HOME/$app" && docker-compose down
        fi
    done

    echo "Restarting infrastructure..."
    cd "$INFRA_DIR" && docker-compose down && docker-compose up -d

    echo "Starting all applications..."
    for app in "${APPS[@]}"; do
        if [ -d "$HOME/$app" ]; then
            cd "$HOME/$app" && docker-compose up -d
        fi
    done
}

case "$1" in
    restart-all)
        restart_all
        ;;
    *)
        echo "Usage: ./manage.sh {restart-all}"
        exit 1
esac
