"""Catalogue Wankul — normalisation et écriture. **La lecture n'est pas branchée.**

Ce module porte tout ce qui ne dépend pas de la source : la forme normalisée
d'une carte, son identité dérivée, l'écriture idempotente en base, et le débit
auquel la source sera interrogée. Ce qu'il ne porte pas encore, c'est la lecture
elle-même — voir [`fetch_all`] et le pourquoi.

**Pourquoi écrire la moitié d'un connecteur.** Les quatre jeux précédents l'ont
montré : ce qui coûte n'est jamais le transport, c'est ce qu'on range dans les
colonnes. Yu-Gi-Oh a payé un prix pris pour une cote, Pokémon un nom pris pour
une identité, Riftbound un champ d'affichage pris pour une clé. Cette partie-là
se décide sans la source, et elle se teste sans réseau.

**L'identité est le numéro d'impression, jamais le nom.** Une carte Wankul porte
un numéro dans son extension, et la leçon Pokémon vaut ici : 92 % du catalogue y
partageait son nom, et dériver l'identité du nom aurait fusionné 112 Pikachu.
Rien ne dit que Wankul soit différent — deux effigies d'un même personnage
(Laink et Terracid) portent des noms proches, et le dump tiers observé montrait
déjà `mort_vivant_laink` et `mort_vivant_terracid` comme deux cartes.

**Ce que ce jeu ne remplit pas, et volontairement.** `cmc`, `mana_cost` et
`color_identity` restent vides : Wankul n'a ni coût d'invocation ni couleur, et
y ranger un analogue de forme referait l'erreur mesurée sur Yu-Gi-Oh, où
l'Attribut logé dans `color_identity` aurait écarté 32 % du catalogue sur une
règle qui n'existe pas. `price_eur` restera nul lui aussi : ce jeu se vend en
direct par son éditeur et n'a aucun marché secondaire coté.

Usage (une fois la lecture branchée) :
    cd api && .venv/Scripts/python -m app.ingestion.wankul_ingest
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from typing import Any, Iterable, Iterator

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

    number: str
    name: str
    set_code: str
    type_line: str
    rarity: str | None = None
    #: Effigie (Laink, Terracid, Guest…). Rangée dans `layout` : c'est une
    #: propriété qui décide de la mise en page, donc de la fenêtre
    #: d'illustration — même usage que le `frameType` de Yu-Gi-Oh.
    effigy: str | None = None
    text: str | None = None

    @property
    def oracle_id(self) -> uuid.UUID:
        """Identité dérivée de l'extension et du numéro, jamais du nom."""
        return uuid.uuid5(NAMESPACE, f"{self.set_code}:{self.number}")


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
                card.effigy,
                GAME,
            )

    written = 0
    with conn.cursor() as cur:
        for row in rows():
            cur.execute(statement, row)
            written += 1
    conn.commit()
    return written


def fetch_all() -> list[WankulCard]:
    """Lit le catalogue à la source. **Pas encore branchée, et à dessein.**

    Trois choses manquent, et aucune n'est du code :

    1. **La trace écrite de l'autorisation.** La table de maintenance du
       `CLAUDE.md` impose de documenter les conditions de chaque source, et le
       garde-fou §IV.1 interdit nommément une source dont les conditions
       prohibent l'extraction. Wankul y échappe par une autorisation nominative
       de LINK DIGITAL SPIRIT : sans le message qui l'établit, le dépôt porterait
       un connecteur que sa propre doctrine interdit, et rien ne permettrait à un
       futur lecteur de faire la différence.
    2. **Le périmètre.** Données factuelles seules, ou illustrations comprises ?
       Le second décide si la reconnaissance photo est possible ; le reste de
       l'application tient sans.
    3. **Le débit accordé.** [`PAUSE_SECONDS`] tient lieu de valeur prudente en
       l'absence de chiffre.

    Lever plutôt que rendre une liste vide : une liste vide se propagerait
    jusqu'à une course qui n'écrirait rien, et le journal dirait « 0 carte » —
    ce qui se lit comme une source tarie, pas comme un connecteur inachevé.
    """
    raise NotImplementedError(
        "La lecture de la source n'est pas branchée : il manque la trace écrite "
        "de l'autorisation, le périmètre accordé et le débit. Voir la docstring "
        "et docs/architecture.md §3."
    )


def main() -> int:
    cards = fetch_all()
    config = SupabaseConfig.load()
    with psycopg.connect(config.db_url, connect_timeout=30) as conn:
        written = write_cards(conn, cards)
    print(f"cartes écrites : {written}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
