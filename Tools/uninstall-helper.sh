#!/bin/zsh
# Run explicitly with sudo after quitting Moka. Never delete an unrestored journal.
set -euo pipefail
[[ $EUID == 0 ]] || { print -u2 'Quittez Moka, puis exécutez : sudo zsh Tools/uninstall-helper.sh'; exit 1; }
LABEL=fr.local.moka.helper
JOURNAL='/Library/Application Support/Moka/session.plist'
PLIST='/Library/LaunchDaemons/fr.local.moka.helper.plist'
if /bin/launchctl print "system/$LABEL" >/dev/null 2>&1; then
  /bin/launchctl bootout "system/$LABEL"
fi
for attempt in {1..15}; do
  [[ ! -e "$JOURNAL" ]] && break
  /bin/sleep 1
done
if [[ -e "$JOURNAL" ]]; then
  /bin/launchctl bootstrap system "$PLIST" 2>/dev/null || true
  print -u2 'Restauration encore nécessaire. Service conservé pour réessayer ; aucune donnée supprimée.'
  exit 1
fi
/bin/rm -f '/Library/PrivilegedHelperTools/fr.local.moka.helper' "$PLIST" '/Library/Application Support/Moka/helper.plist'
/bin/rmdir '/Library/Application Support/Moka' 2>/dev/null || true
print 'Service Moka supprimé. Les réglages précédents ont été conservés.'
