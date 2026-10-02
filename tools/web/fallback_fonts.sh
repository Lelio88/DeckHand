#!/bin/sh
# Ajoute à un « flutter build web » les polices de secours du moteur Flutter
# (familles Noto : emoji, alphabets non latins), pour que DeckHand les serve
# lui-même au lieu de laisser le navigateur les chercher chez Google
# (noms de cartes en japonais ou en chinois, emoji).
#
# Choix non évidents :
#   - la liste n'est pas tenue à la main : elle est relevée dans main.dart.js,
#     où le moteur l'embarque avec les versions exactes qu'il demandera. Elle
#     suit donc d'elle-même chaque montée de Flutter ;
#   - les fichiers sont copiés au build, pas versionnés : 725 fichiers et
#     ~21 Mo de binaires n'ont pas leur place dans un dépôt public ;
#   - web/flutter_bootstrap.js pointe le moteur sur /fonts/fallback/ ; le
#     moteur n'en charge qu'un fichier à la fois, quand un caractère l'exige ;
#   - pas d'empreintes figées : la liste change avec Flutter. La confiance
#     reste celle d'avant (le navigateur prenait ces mêmes fichiers, en HTTPS,
#     à la même source), et le navigateur assainit toute police avant usage.
#
# Invariant : le build échoue si un seul fichier manque, ou si la liste n'est
# plus trouvée (format du moteur changé) ; jamais de copie partielle en ligne.
#
#   sh tools/web/fallback_fonts.sh app/build/web   (lancé par .github/workflows/pages.yml)
set -eu

web=${1:?usage: fallback_fonts.sh <dossier du build web>}
dest="$web/fonts/fallback"
source_url=https://fonts.gstatic.com/s
# Le moteur en demande plusieurs centaines : en deçà, l'extraction a raté.
min_expected=100

list=$(grep -o '"[a-z0-9]*/v[0-9]*/[A-Za-z0-9_.-]*\.\(woff2\|ttf\|otf\)"' "$web/main.dart.js" \
    | tr -d '"' | sort -u)
count=$(printf '%s\n' "$list" | grep -c . || true)
if [ "$count" -lt "$min_expected" ]; then
    echo "fallback_fonts : $count police(s) relevée(s) dans main.dart.js, $min_expected attendues au moins" >&2
    exit 1
fi

config=$(mktemp)
trap 'rm -f "$config"' EXIT
printf '%s\n' "$list" | while read -r path; do
    printf 'url = "%s/%s"\noutput = "%s/%s"\n' "$source_url" "$path" "$dest" "$path"
done > "$config"

curl --silent --show-error --fail --retry 3 --create-dirs \
    --parallel --parallel-max 16 --config "$config"

got=$(find "$dest" -type f \( -name '*.woff2' -o -name '*.ttf' -o -name '*.otf' \) | wc -l)
if [ "$got" -ne "$count" ]; then
    echo "fallback_fonts : $got fichier(s) copié(s) sur $count" >&2
    exit 1
fi
echo "fallback_fonts : $count polices de secours copiées dans $dest"
