"""Catalogue Wankul, depuis le Wankuldex.

**Source autorisée nominativement** par LINK DIGITAL SPIRIT, éditeur du jeu : ses
conditions (article 4) interdisent sinon toute collecte automatisée, et le
garde-fou §IV.1 du `CLAUDE.md` en fait un motif d'exclusion — c'est ce qui a
écarté EDHREC. Wankul y échappe par cette autorisation, et par elle seule.

**Ce que l'autorisation ne couvre pas : les illustrations.** Leur accès direct
rend un `403 Hotlinking not allowed` explicite, qui n'est pas une panne mais une
politique. Elles ne sont donc ni téléchargées ni référencées ici ; lever ce
blocage demande un geste de l'éditeur.

**L'identité vient de l'identifiant de la source, pas du numéro.** Le couple
extension-numéro paraissait suffire et fusionnait 15 cartes sur 958 : « Hors
Série » agrège des sous-collections — PGW 2023 et 2024, Starter Packs, Booster
Gold, Gala TCG — dont chacune recommence sa numérotation, si bien que
`hors-serie:1` désigne quatre cartes. Le défaut a été pris à la première course,
avant qu'une collection ne pointe sur ces clés.

**Ce que ce jeu ne remplit pas, et volontairement.** `cmc`, `mana_cost` et
`color_identity` restent vides : Wankul n'a ni coût d'invocation ni couleur, et
y ranger un analogue de forme referait l'erreur mesurée sur Yu-Gi-Oh, où
l'Attribut logé dans `color_identity` aurait écarté 32 % du catalogue sur une
règle qui n'existe pas. `price_eur` reste nul lui aussi : ce jeu se vend en
direct par son éditeur et n'a aucun marché secondaire coté.

Usage :
    cd api && .venv/Scripts/python -m app.ingestion.wankul_ingest
"""

from __future__ import annotations

import time
import uuid
from dataclasses import dataclass
from typing import Any, Iterable, Iterator

import httpx
import psycopg

from app.config import SupabaseConfig

GAME = "wankul"

#: Espace de noms des identifiants dérivés. **Figé** : le changer réécrirait tout
#: le catalogue sous de nouvelles clés et orphelinerait les collections déjà
#: saisies — chaque exemplaire possédé pointe sur un `oracle_id`.
NAMESPACE = uuid.uuid5(uuid.NAMESPACE_URL, "https://deckhand.local/wankul")

USER_AGENT = (
    "DeckHand/1.0 (collection perso, non commercial; "
    "contact via github.com/Lelio88/DeckHand)"
)

#: Le Wankuldex est une application servie par un *app proxy* Shopify : la
#: boutique relaie `/apps/wankul/**` vers un service qui, lui, parle JSON.
#:
#: **Les routes ne sont pas devinées, elles sont lues.** Le bundle de
#: l'application les déclare toutes ; les chercher par essais aurait produit une
#: volée de 404 pour le même résultat. `window.__WANKULDEX_CONFIG__` donne la
#: base du proxy, le bundle donne le reste.
BASE = "https://wankul.fr/apps/wankul"
ROUTE_SETS = "/api/wankuldex/sets"
ROUTE_CARDS = "/api/wankuldex/cards/{slug}"
ROUTE_RARITIES = "/api/wankuldex/rarities"
ROUTE_EFFIGIES = "/api/wankuldex/effigies"
ROUTE_ARTISTS = "/api/wankuldex/artists"

#: Les six extensions et leur volume, relevés sur `ROUTE_SETS`.
#:
#: Sert de garde-fou de complétude : une course qui rendrait nettement moins que
#: 958 cartes a rencontré un mur, et le journal doit le dire plutôt que
#: d'enregistrer un catalogue amputé. Les valeurs viennent du champ `cardCount`
#: publié par la source, pas d'un comptage maison.
EXPECTED_CARDS = {
    "origins": 180,
    "campus": 155,
    "battle": 180,
    "stellar": 180,
    "legacy": 185,
    "hors-serie": 78,
}
EXPECTED_TOTAL = sum(EXPECTED_CARDS.values())  # 958

#: Champs servis par `/api/wankuldex/cards`, relevés sur la source :
#: `id`, `name`, `number`, `effigy{id,name,slug}`, `imageUrl`, `imagePaysage`,
#: `imageUR`, `imageLeg`, `holoMasks`, `set`, `rarity`, `artist`.


def orientation_of(card: dict) -> str:
    """`horizontal` ou `vertical`, déduits du rendu et non du champ homonyme.

    **Le champ `orientation` de la source ne dit pas comment la carte est
    imprimée.** Mesuré : `?orientation=horizontal` rend 40 cartes dont 13 sont
    debout — les promos PGW 2023, 2024, 2025 et une Édition Spéciale. Trois
    d'entre elles ont été confrontées à leur rendu, qui fait 751 x 1059 : des
    cartes verticales, annoncées horizontales.

    Ce qui distingue réellement les deux maquettes est la présence d'un rendu
    **paysage**. Les 27 Terrains du même lot en ont un ; aucune des 13 autres.

    C'est le même piège que `Advanced` chez Yu-Gi-Oh — un format déclaré sur la
    foi de son nom, qui portait 3 decklists — et que le classement Limitless,
    pris pour une identité alors qu'il valait `null`. Un nom de champ n'est pas
    un contrat ; ce que le champ contient, mesuré, en est un.
    """
    return "horizontal" if card.get("imagePaysage") else "vertical"

#: Une requête toutes les deux secondes.
#:
#: **Le plus prudent des débits pratiqués par le projet**, et c'est délibéré
#: tant que l'éditeur n'a pas donné de chiffre. Scryfall tolère 10 req/s,
#: TopDeck.gg 100/min, et les sources sans conditions publiées reçoivent le
#: régime Scryfall (garde-fou §IV.9). Ici l'autorisation est nominative : la
#: dépasser coûterait bien plus qu'elle ne ferait gagner, et le catalogue tient
#: en quelques centaines de cartes — la course entière dure quelques minutes à
#: ce rythme.
PAUSE_SECONDS = 2.0


@dataclass(frozen=True)
class WankulCard:
    """Une carte, telle que la base l'attend.

    Cette forme est le contrat entre la lecture et l'écriture : elle est ce que
    `fetch_all` devra produire, quelle que soit la façon dont la source la sert.
    Les tests écrivent des `WankulCard` à la main, sans réseau.
    """

    #: Identifiant de la carte chez la source.
    #:
    #: **C'est lui qui fait l'identité, et le numéro n'y suffisait pas.**
    #: Mesuré : le couple extension-numéro fusionnait 15 cartes sur 958. Dans
    #: « Hors Série », qui agrège des sous-collections — PGW 2023, PGW 2024,
    #: Starter Packs, Booster Gold, Gala TCG —, chacune recommence sa
    #: numérotation : `hors-serie:1` désigne quatre cartes différentes, dont
    #: « CHIEN - PGW 2024 » et « PIRATE - PGW 2023 ».
    #:
    #: Ajouter la rareté à la clé les séparerait, mais ferait dépendre l'identité
    #: de trois champs d'affichage — ce que #29 a coûté sur Riftbound. Un
    #: identifiant technique n'est pas un champ d'affichage : c'est le choix
    #: déjà retenu pour Pokémon, dont l'identité est celle de TCGdex.
    source_id: int
    number: str
    name: str
    set_code: str
    type_line: str
    rarity: str | None = None
    #: `vertical` ou `horizontal`. **C'est elle qui va dans `layout`, et non
    #: l'effigie**, contrairement à ce que ce module prévoyait d'abord.
    #:
    #: La correction vient d'une carte : « Road Trip » est horizontale, et ses
    #: bandeaux de texte occupent 0,186 à 0,418 de la hauteur — des proportions
    #: qui n'ont aucun sens sur une carte verticale. `layout` sert à choisir le
    #: gabarit d'illustration ; ce qui le décide ici est l'orientation, comme
    #: chez Riftbound. L'effigie, elle, dit de quel personnage la carte porte le
    #: visage : une information de contenu, pas de mise en page.
    orientation: str | None = None
    #: Laink, Terracid, Guest… Conservée pour la recherche, pas pour le gabarit.
    effigy: str | None = None
    text: str | None = None

    @property
    def oracle_id(self) -> uuid.UUID:
        """Identité dérivée de l'identifiant de la source, jamais du nom."""
        return uuid.uuid5(NAMESPACE, f"card:{self.source_id}")


def write_cards(conn: psycopg.Connection, cards: Iterable[WankulCard]) -> int:
    """Écrit l'identité des cartes. Idempotent : rejouable sans doublon."""
    statement = """
        INSERT INTO public.cards (oracle_id, name, type_line, oracle_text,
                                  color_identity, legalities, layout, game,
                                  updated_at)
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, NOW())
        ON CONFLICT (oracle_id) DO UPDATE SET
            name        = EXCLUDED.name,
            type_line   = EXCLUDED.type_line,
            oracle_text = EXCLUDED.oracle_text,
            layout      = EXCLUDED.layout,
            game        = EXCLUDED.game,
            updated_at  = NOW()
    """

    def rows() -> Iterator[tuple[Any, ...]]:
        seen: set[uuid.UUID] = set()
        for card in cards:
            if card.oracle_id in seen:
                continue
            seen.add(card.oracle_id)
            yield (
                str(card.oracle_id),
                card.name,
                card.type_line,
                card.text,
                # Vide, et non « aucune couleur » : ce jeu n'a pas de couleurs.
                [],
                "{}",
                card.orientation,
                GAME,
            )

    written = 0
    with conn.cursor() as cur:
        for row in rows():
            cur.execute(statement, row)
            written += 1
    conn.commit()
    return written


def card_from(payload: dict) -> WankulCard:
    """Une carte de la source, ramenée à la forme que la base attend."""
    effigy = (payload.get("effigy") or {}).get("name")
    rarity = (payload.get("rarity") or {}).get("name")
    orientation = orientation_of(payload)
    return WankulCard(
        source_id=int(payload["id"]),
        number=str(payload.get("number") or payload["id"]),
        name=payload.get("name") or "",
        set_code=(payload.get("set") or {}).get("slug") or "?",
        # **Le type se déduit du rendu, faute d'un champ qui le porte.** La
        # source n'en publie aucun : « Terrain » y est à la fois une rareté et
        # une effigie, et ni l'une ni l'autre ne suffit — la carte « Ouverture
        # de Colis » est un Terrain (T#201) de rareté « Edition Gold ». Le rendu
        # paysage, lui, ne suit que la maquette, et la maquette suit le type.
        type_line="Terrain" if orientation == "horizontal" else "Personnage",
        rarity=rarity,
        orientation=orientation,
        effigy=effigy,
    )


#: Combien de fois un lot est redemandé après un 503.
#:
#: La source en rend de façon **intermittente** : la course d'essai en a reçu un
#: seul sur trente lots, et il a coûté 79 cartes. Sans reprise, une extension
#: entière manque et le total final ne le dit qu'après coup.
RETRIES = 3


def fetch_all(sleep=time.sleep, client=None) -> list[WankulCard]:
    """Le catalogue entier, découpé par extension et par effigie.

    **La pagination est cassée au-delà de la première page.** Mesuré :
    `?page=1` rend 200, `?page=2` rend un 503 déterministe, et `limit` plafonne
    à 100 quoi qu'on demande. Le catalogue fait 958 cartes en six extensions
    dont cinq dépassent la centaine : il faut donc un second axe.

    C'est exactement le piège de TCGdex sur Pokémon, dont l'argument
    `pagination` existait avec un resolveur cassé — et il a fallu bissecter
    seize champs avant de comprendre que l'argument était en cause.

    **Deux axes ont été essayés, le moins coûteux gagne.** `rarity` découpe en
    27 valeurs, `effigy` en cinq : 30 requêtes contre 162 pour le même
    résultat. `setId` est ignoré par la source — c'est `set`, par son slug, qui
    filtre ; le premier rendait le catalogue entier en annonçant l'avoir
    filtré, ce qui est le pire des deux comportements.

    Le total de chaque lot est comparé à celui que la source annonce, et le
    total général à [EXPECTED_TOTAL] : une course qui rendrait moins a rencontré
    un mur, et doit le dire.
    """
    cartes: dict[str, WankulCard] = {}
    manques: list[str] = []
    proprietaire = client is None
    if proprietaire:
        client = httpx.Client(
            headers={"User-Agent": USER_AGENT, "Accept": "application/json"},
            timeout=60,
            follow_redirects=True,
        )

    def lire(params: dict) -> dict | None:
        """Un lot, réessayé tant que la source rend un 503."""
        for tentative in range(RETRIES):
            sleep(PAUSE_SECONDS * (tentative + 1))
            r = client.get(f"{BASE}/api/wankuldex/cards", params=params)
            if r.status_code == 200:
                return r.json()
            if r.status_code != 503:
                return None
        return None

    try:
        sleep(PAUSE_SECONDS)
        effigies = client.get(f"{BASE}{ROUTE_EFFIGIES}").json()["data"]
        slugs = [e["slug"] for e in effigies]

        for set_slug in EXPECTED_CARDS:
            for effigy in slugs:
                corps = lire({"set": set_slug, "effigy": effigy,
                              "limit": 100, "page": 1})
                if corps is None:
                    manques.append(f"{set_slug}/{effigy}: illisible")
                    continue
                lot = corps.get("data", [])
                annonce = (corps.get("meta") or {}).get("total", len(lot))
                if annonce > len(lot):
                    # Un lot tronqué par le plafond de 100 : le signaler plutôt
                    # que d'enregistrer un catalogue amputé en silence.
                    manques.append(
                        f"{set_slug}/{effigy}: {len(lot)} rendus sur {annonce}")
                for payload in lot:
                    carte = card_from(payload)
                    cartes[str(carte.oracle_id)] = carte
    finally:
        if proprietaire:
            client.close()

    if manques:
        print("  lots incomplets :")
        for m in manques:
            print(f"    {m}")
    if len(cartes) < EXPECTED_TOTAL:
        print(f"  ATTENTION : {len(cartes)} cartes pour {EXPECTED_TOTAL} "
              f"attendues — il manque {EXPECTED_TOTAL - len(cartes)}")
    return list(cartes.values())


def main() -> int:
    cards = fetch_all()
    config = SupabaseConfig.load()
    with psycopg.connect(config.db_url, connect_timeout=30) as conn:
        written = write_cards(conn, cards)
    print(f"cartes écrites : {written}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
