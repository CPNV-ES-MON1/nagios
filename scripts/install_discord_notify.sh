#!/bin/bash

#
# install_discord_notify.sh
# Installe le script de notification Discord pour NagiosXI
#

set -e

SCRIPT_NAME="discord_curl.sh"
DEST1="/usr/local/nagiosxi/html/includes/configwzards/eventhandler_notify_discord/plugins/discord_curl.sh"
DEST2="/usr/local/nagiosxi/scripts/discord_curl.sh"

# Vérifier que le script source est présent
if [ ! -f "$SCRIPT_NAME" ]; then
    echo "❌  Erreur : '$SCRIPT_NAME' introuvable dans le répertoire courant."
    echo "    Lance ce script depuis le dossier où se trouve $SCRIPT_NAME."
    exit 1
fi

# Vérifier les droits root
if [ "$EUID" -ne 0 ]; then
    echo "❌  Erreur : ce script doit être exécuté en tant que root (sudo)."
    exit 1
fi

echo "📋  Copie de $SCRIPT_NAME vers les destinations NagiosXI..."

cp "$SCRIPT_NAME" "$DEST1"
echo "    ✅  $DEST1"

cp "$SCRIPT_NAME" "$DEST2"
echo "    ✅  $DEST2"

echo ""
echo "🔐  Application des permissions d'exécution..."

chmod +x "$DEST1"
echo "    ✅  chmod +x $DEST1"

chmod +x "$DEST2"
echo "    ✅  chmod +x $DEST2"

echo ""
echo "🎉  Installation terminée avec succès !"
