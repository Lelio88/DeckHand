"""Versement du dos des cartes de chaque jeu dans le dépôt d'images.

**Pourquoi le dos ne se pointe pas chez sa source, alors que tout le reste s'y
pointe.** Le calque de direct est une *browser source* OBS : une image que son
hôte sert sans en-tête CORS s'y fait bloquer **en silence**, et l'écran retombe
sur un motif dessiné sans qu'aucun code de retour ne le dise. Mesuré le
2026-09-11, en-tête `Origin` en main : `backs.scryfall.io` envoie
`Access-Control-Allow-Origin: *`, `images.ygoprodeck.com` n'envoie rien. Le
bucket `card-art`, lui, le sert à tous — et il ne tombe pas avec le CDN d'un
tiers au milieu d'un direct. Tous les dos y vivent donc, en `<jeu>/back.jpg`,
et `cardBackUrl` côté Dart dérive la même adresse de l'URL du projet.

**Ce module copie, ce que le projet ne fait nulle part ailleurs — et il ne le
fait que sur parole écrite.** La règle est de ne jamais réhéberger l'image
d'une source (§IV.3, §IV.9) ; le bucket n'est pas un cache générique, un jeu y
entre avec son propre accord (§IV.10). [SOURCES] est cet accord, jeu par jeu,
cité : un jeu qui n'y figure pas est **refusé**, même avec un fichier sous la
main. Le jour où un éditeur donne un dos, on l'inscrit d'abord ici, avec ce
qu'il a écrit — puis on le verse avec `--file`.

**`--scan` est l'autre porte, et elle ne copie personne** : le fichier vient
d'une carte possédée, pas d'une source. Rien n'est alors réhébergé, donc la
table n'a pas à donner son accord — mais le contrôle du fichier, lui, reste
entier.

**Et il n'y a rien à inventer.** Six jeux sur huit n'ont pas de dos publié par
une source que le projet utilise (vérifié source par source, API, docs et
bundles de leurs sites) ; en deviner l'URL sur le CDN d'un éditeur serait au
mieux un 404, au pire une ressource qu'on n'a pas le droit de servir. Ces six-là
gardent le motif dessiné de `sheet_face.dart`.

**Le fichier est versé tel quel.** Pas de réencodage : Scryfall demande de ne
pas déformer ni retoucher ses images, et un JPEG réencodé est une génération de
perdue pour rien. Le module vérifie seulement que c'est un JPEG portrait aux
proportions du jeu — un dos Magic versé sous `yugioh/` se verrait à l'écran,
jamais dans une revue.

**Le versement se vérifie comme le calque le lira.** Après le `PUT`, une lecture
publique part avec l'`Origin` du calque et exige l'en-tête CORS : c'est la seule
preuve qui vaille, et c'est ce qui manquait à la première version.

Usage :
    cd api && .venv/Scripts/python -m app.ingestion.card_back_upload            # tous
    cd api && .venv/Scripts/python -m app.ingestion.card_back_upload yugioh     # un seul
    cd api && .venv/Scripts/python -m app.ingestion.card_back_upload <jeu> --file <chemin>
    cd api && .venv/Scripts/python -m app.ingestion.card_back_upload <jeu> --file <chemin> --scan
"""

from __future__ import annotations

import io
import sys
from dataclasses import dataclass
from pathlib import Path

import httpx
from PIL import Image, UnidentifiedImageError

from app.card_art import back_path, back_url, upload
from app.config import SupabaseConfig
from app.vision.card_geometry import CARD_ASPECTS, card_aspect_for

USER_AGENT = (
    "DeckHand/1.0 (collection perso, non commercial; "
    "contact via github.com/Lelio88/DeckHand)"
)

#: L'origine depuis laquelle le calque lit le bucket — `shareBaseUrl`, côté
#: Dart. C'est avec elle que la vérification CORS doit être faite : un `curl`
#: sans `Origin` ne prouve rien, l'hôte peut ne répondre qu'aux navigateurs.
OVERLAY_ORIGIN = "https://lelio88.github.io"

#: Tolérance sur le rapport largeur/hauteur. Le dos Yu-Gi-Oh publié fait 0,697
#: pour un carton à 0,686 (écart 0,011), celui de Magic 0,718 pour 0,716 : le
#: peintre recadre au centre, un écart de cet ordre ne se voit pas. Les deux
#: dos échangés, eux, s'écartent de 0,019 et 0,032 — juste assez pour que le
#: seuil les sépare, et il est réglé sur ces quatre nombres, pas au jugé.
ASPECT_TOLERANCE = 0.015


@dataclass(frozen=True)
class Source:
    """D'où vient le dos d'un jeu, et ce que sa source écrit qui autorise la copie.

    `url` vaut `None` quand le fichier est remis hors ligne — un éditeur qui
    donne un dos sans le publier. Le versement passe alors par `--file`.
    """

    url: str | None
    basis: str


#: Les seuls dos que ce module accepte de verser. **La table est l'accord.**
SOURCES: dict[str, Source] = {
    "magic": Source(
        url=(
            "https://backs.scryfall.io/normal/"
            "0/a/0aeebaf5-8c7d-4636-9e82-8c27447861f7.jpg"
        ),
        basis=(
            "Scryfall : « provides our card data and image database free of "
            "charge for the primary purpose of creating additional Magic "
            "software » ; interdit le paywall, le repackaging et la "
            "déformation, rien de la copie. Le dos reste © Wizards of the "
            "Coast, sous sa Fan Content Policy — usage privé, non commercial."
        ),
    ),
    "yugioh": Source(
        url="https://images.ygoprodeck.com/images/cards/back.jpg",
        basis=(
            "YGOPRODeck, guide d'API : « Do not continually hotlink images "
            "directly from this site. Please download and re-host the images "
            "yourself. » La copie n'est pas tolérée, elle est demandée."
        ),
    ),
    # `url=None` : l'accord couvre la copie, mais aucun dos n'est publié ni
    # n'était dans le lot fourni. Il se demande, puis `--file`.
    "wankul": Source(
        url=None,
        basis=(
            "LINK DIGITAL SPIRIT, éditeur du jeu : autorisation nominative "
            "couvrant la copie comme la collecte (§IV.10), celle-là même qui "
            "autorise les vignettes déjà versées."
        ),
    ),
}

#: Riftbound n'y est pas : la *Legal Jibber Jabber* de Riot refuse son IP
#: « in a game or app », ce que DeckHand est. Il faudrait l'accès approuvé à
#: l'API Riftbound, que la clé de développement n'obtient pas (403).


def fetch(client: httpx.Client, url: str) -> bytes:
    """Le fichier publié par la source, en une requête."""
    response = client.get(url, headers={"User-Agent": USER_AGENT})
    if response.status_code != 200:
        raise RuntimeError(f"{url} : HTTP {response.status_code}")
    return response.content


def check(payload: bytes, game: str) -> str | None:
    """Ce qui disqualifie un fichier, ou `None` s'il peut être versé.

    Un JPEG, debout, aux proportions du jeu : c'est ce que le peintre attend, et
    c'est ce qu'un mauvais fichier — un PNG, une page entière, le dos d'un autre
    jeu — trahirait à l'écran seulement.
    """
    try:
        image = Image.open(io.BytesIO(payload))
        image.load()
    except (UnidentifiedImageError, OSError) as erreur:
        return f"illisible : {erreur}"
    if image.format != "JPEG":
        return f"format {image.format}, JPEG attendu"
    width, height = image.size
    if width >= height:
        return f"{width} × {height} : un dos se verse debout"
    ecart = abs(width / height - card_aspect_for(game))
    if ecart > ASPECT_TOLERANCE:
        return (
            f"rapport {width / height:.3f} contre {card_aspect_for(game):.3f} "
            f"attendu pour {game} — le dos d'un autre jeu ?"
        )
    return None


def verify_cors(client: httpx.Client, url: str) -> str | None:
    """Relit l'objet comme le calque le fera. `None` si le navigateur le verra."""
    response = client.get(url, headers={"Origin": OVERLAY_ORIGIN})
    if response.status_code != 200:
        return f"HTTP {response.status_code}"
    if "access-control-allow-origin" not in response.headers:
        return "aucun en-tête Access-Control-Allow-Origin"
    return None


def run(
    games: list[str],
    file: Path | None = None,
    scan: bool = False,
    config: SupabaseConfig | None = None,
    client: httpx.Client | None = None,
) -> int:
    """Verse le dos des jeux demandés. Rend 1 si l'un d'eux a échoué.

    `scan` déclare que le fichier vient d'une **carte possédée**, et non d'une
    source : rien n'est alors copié à personne, et la table n'a pas à donner son
    accord. Le fichier reste contrôlé comme les autres — un scan de travers ou
    le dos d'un autre jeu se refuse ici plutôt qu'à l'écran.

    `config` et `client` sont injectables pour le test.
    """
    if file is not None and len(games) != 1:
        sys.exit("--file s'applique à un jeu, et un seul")
    if scan and file is None:
        sys.exit("--scan attend le fichier scanné : --file <chemin>")
    if scan:
        # Un jeu que le projet ne connaît pas est une faute de frappe, et elle
        # se verrait comme un 404 muet sous un préfixe inventé.
        etrangers = [g for g in games if g not in CARD_ASPECTS]
        if etrangers:
            sys.exit(f"jeu inconnu du projet : {', '.join(etrangers)}")
    else:
        inconnus = [g for g in games if g not in SOURCES]
        if inconnus:
            sys.exit(
                f"aucune base écrite pour {', '.join(inconnus)} — l'inscrire dans "
                "SOURCES avec ce que la source autorise, avant de verser quoi que "
                "ce soit. Un dos scanné d'une carte possédée passe par --scan."
            )
    if not games:
        games = [g for g, s in SOURCES.items() if s.url is not None]

    config = config or SupabaseConfig.load()
    # Ne fermer que ce que l'on a ouvert : un client injecté appartient à
    # l'appelant, qui peut s'en resservir après.
    a_nous = client is None
    client = client or httpx.Client(timeout=60, follow_redirects=True)
    echecs = 0
    try:
        for game in games:
            source = SOURCES.get(game)
            try:
                if file is not None:
                    payload = file.read_bytes()
                elif source is not None and source.url is not None:
                    payload = fetch(client, source.url)
                else:
                    raise RuntimeError("remis hors ligne : passer --file")
                raison = check(payload, game) or upload(
                    client, config.url, config.service_key, back_path(game), payload
                )
                if raison is None:
                    raison = verify_cors(client, back_url(config.url, game))
            except (RuntimeError, OSError, httpx.HTTPError) as erreur:
                raison = str(erreur)
            if raison is None:
                origine = "scanné" if scan else "versé"
                print(f"  {game} : {origine} et relu avec CORS — {back_url(config.url, game)}")
            else:
                echecs += 1
                print(f"  {game} : ÉCHEC — {raison}")
    finally:
        if a_nous:
            client.close()
    return 1 if echecs else 0


def _parse(argv: list[str]) -> tuple[list[str], Path | None, bool]:
    games: list[str] = []
    file: Path | None = None
    scan = False
    it = iter(argv)
    for arg in it:
        if arg == "--file":
            chemin = next(it, None)
            if chemin is None:
                sys.exit("--file attend un chemin")
            file = Path(chemin)
        elif arg == "--scan":
            scan = True
        else:
            games.append(arg)
    return games, file, scan


if __name__ == "__main__":
    raise SystemExit(run(*_parse(sys.argv[1:])))
