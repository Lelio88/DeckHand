"""Le dépôt d'images de cartes, quand la source refuse de servir les siennes.

**Une exception, pas une commodité.** La règle du projet est de ne jamais
réhéberger l'illustration d'une source : on pointe l'URL de l'éditeur et l'on
n'en garde rien (§IV.3, §IV.9). Wankul ne le permet pas — son CDN rend
`403 Hotlinking not allowed` sans `Referer`, avec un `Referer` étranger, et
jusqu'avec celui de `wankul.fr`. C'est une politique, pas un en-tête à ajuster.
LINK DIGITAL SPIRIT, éditeur du jeu, a accordé la copie nominativement, au même
titre que la collecte du catalogue (§IV.10).

**Ce bucket n'est donc pas un cache générique.** Un autre jeu n'y entre pas
parce que son CDN a eu un hoquet : il y entre avec son propre accord. Le préfixe
de jeu dans le chemin est là pour que la question se pose à chaque fois.

**Le chemin imite celui de Scryfall, et c'est ce qui rend le Dart inutile à
modifier.** L'application affiche déjà une vignette légère avant la grande, en
échangeant un segment d'URL (`previewCardImage` : `/normal/` → `/small/`).
Calquer la convention donne les deux paliers gratuitement ; s'en écarter aurait
demandé un cas particulier dans un module que les cinq jeux partagent.

L'identifiant du chemin est l'`illustration_id` de l'impression — celui que la
source donne à son rendu. Il est **déterministe** : l'ingestion calcule l'URL
sans savoir ce que le bucket contient, et un versement incomplet se lit comme un
404 sur une carte, pas comme une base incohérente.

Exemple canonique :

    >>> public_url("https://abc.supabase.co", "wankul", FULL, "b4372ef1-…")
    'https://abc.supabase.co/storage/v1/object/public/card-art/wankul/normal/b4372ef1-….jpg'
"""

from __future__ import annotations

import io

from PIL import Image

#: Bucket public, créé par `20260817100000_card_art_bucket.sql`.
BUCKET = "card-art"

#: Palier plein — la carte à sa résolution d'origine. Nommé comme chez Scryfall.
FULL = "normal"

#: Palier léger, chargé en premier pour que la page de classeur dise quelque
#: chose tout de suite. Même nom, même rôle, même bénéfice : mesuré sur Wankul,
#: 10,1 Kio contre 60,2 — une double page passe de 1,1 Mio à 182 Kio.
SMALL = "small"

#: Plus grand côté du palier léger. Une carte debout y tombe en 146 × 204, la
#: taille que le projet emploie déjà pour Scryfall — elle suffit à reconnaître
#: ses propres cartes, ce qui est tout ce qu'on demande à une case de classeur.
#:
#: **Un plus grand côté, et non une boîte fixe.** Imposer 146 × 204 écrasait les
#: Terrains, qui sont couchés : leur grande sortait en 600 × 430 et leur vignette
#: en 146 × 204, deux proportions différentes pour la même carte. L'application
#: pose la seconde sur la première sans transition (`gaplessPlayback`) : la
#: déformation se serait vue à l'œil, en mouvement, sur les 146 Terrains.
SMALL_MAX_SIDE = 204

#: Qualité JPEG. Mesurée : q82 rend 60,2 Kio par carte contre 66,9 à q88, pour
#: une différence invisible sur un écran de téléphone. Ces images ne servent
#: **pas** au calcul d'empreinte — celui-ci part des fichiers d'origine —, donc
#: la compression avec perte n'a ici aucune conséquence sur la reconnaissance.
QUALITY = 82


def object_path(game: str, tier: str, illustration_id: str) -> str:
    """Chemin de l'objet dans le bucket."""
    return f"{game}/{tier}/{illustration_id}.jpg"


def public_url(base_url: str, game: str, tier: str, illustration_id: str) -> str:
    """URL publique d'un rendu. Sert de `art_crop_url` pour le palier plein.

    `base_url` est l'URL du projet Supabase. La route `/object/public/` sert
    sans jeton : le bucket est public, et ce chemin contourne la RLS par
    construction.
    """
    return (
        f"{base_url.rstrip('/')}/storage/v1/object/public/"
        f"{BUCKET}/{object_path(game, tier, illustration_id)}"
    )


def encode(image: Image.Image, tier: str) -> bytes:
    """Le rendu prêt à verser, dans le palier demandé.

    Tout est ramené en JPEG : le lot d'origine mêle 773 JPEG et 185 PNG, et un
    PNG de photo pèse plusieurs fois son équivalent JPEG sans rien apporter à
    l'écran.
    """
    prepared = image.convert("RGB")
    if tier == SMALL:
        prepared = prepared.copy()
        prepared.thumbnail((SMALL_MAX_SIDE, SMALL_MAX_SIDE), Image.LANCZOS)
    buffer = io.BytesIO()
    prepared.save(buffer, "JPEG", quality=QUALITY, optimize=True)
    return buffer.getvalue()
