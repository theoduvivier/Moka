#!/bin/zsh
# Run explicitly with sudo after quitting Moka. Never delete an unrestored journal.
set -euo pipefail
[[ $EUID == 0 ]] || { print -u2 'Quittez Moka, puis exécutez : sudo zsh Tools/uninstall-helper.sh'; exit 1; }
LABEL=fr.local.moka.helper
JOURNAL='/Library/Application Support/Moka/session.plist'
PLIST='/Library/LaunchDaemons/fr.local.moka.helper.plist'
DIRECTORY='/Library/Application Support/Moka'
# Do not traverse a replaced or writable parent while running as root.
for directory in /Library '/Library/Application Support' /Library/PrivilegedHelperTools /Library/LaunchDaemons "$DIRECTORY"; do
  [[ ! -L "$directory" ]] || { print -u2 'Dossier système inattendu ; service conservé.'; exit 78; }
  if [[ -e "$directory" ]]; then
    [[ -d "$directory" && "$(/usr/bin/stat -f %u "$directory")" == 0 ]] || exit 78
    permissions=$(/usr/bin/stat -f %Lp "$directory")
    (( (8#$permissions & 8#22) == 0 )) || exit 78
  fi
done
[[ ! -L "$JOURNAL" && ! -L "$PLIST" ]] || exit 78
# A stopped daemon may still own a recovery journal. Let it restore that state
# before requesting a graceful shutdown; never discard the journal ourselves.
if [[ -e "$JOURNAL" ]] && ! /bin/launchctl print "system/$LABEL" >/dev/null 2>&1; then
  /bin/launchctl bootstrap system "$PLIST"
  for attempt in {1..15}; do
    [[ ! -e "$JOURNAL" ]] && break
    /bin/sleep 1
  done
  if [[ -e "$JOURNAL" ]]; then
    print -u2 'Restauration encore nécessaire. Service conservé pour réessayer ; aucune donnée supprimée.'
    exit 1
  fi
fi
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
/bin/rm -f '/private/var/run/fr.local.moka-lid.result'
/bin/rmdir '/Library/Application Support/Moka' 2>/dev/null || true
print 'Service Moka supprimé. Les réglages précédents ont été conservés.'
