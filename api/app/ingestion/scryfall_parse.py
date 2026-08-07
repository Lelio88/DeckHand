"""Transformation des payloads Scryfall vers les modèles DeckHand.

Ce module est volontairement **pur** : aucun accès réseau, aucun accès base. Il ne
fait que traduire du JSON Scryfall en structures internes, ce qui le rend entièrement
testable à partir de payloads figés.

Choix non évidents :
  * Le **nom oracle anglais fait foi** partout, y compris pour les impressions
    françaises. Les decklists des sources et les règles des formats sont en anglais ;
    tout résoudre vers l'oracle évite d'avoir deux référentiels de noms.
  * La **normalisation des noms** retire les accents et unifie les apostrophes. C'est ce
    qui permet à l'utilisateur de taper « ile » ou « urza's » sans se soucier de la
    typographie exacte de la carte.
  * L'illustration des cartes recto-verso vit dans `card_faces`, pas à la racine du
    payload. `parse_print` retombe donc sur la première face qui en possède une.

Invariant : une carte sans `oracle_id` est une anomalie de données et lève `ValueError`
plutôt que d'être silencieusement ignorée — mieux vaut un import qui échoue bruyamment
qu'un catalogue troué.
"""

from __future__ import annotations

import unicodedata
from dataclasses import dataclass, field
from typing import Any

# Les trois formats couverts par DeckHand. Une carte légale dans aucun d'eux
# n'a pas à entrer dans le catalogue.
RELEVANT_FORMATS: tuple[str, ...] = ("pauper", "modern", "commander")

# Variantes typographiques d'apostrophe rencontrées dans les noms de cartes.
_APOSTROPHES = "’ʼ‘´`"


@dataclass(frozen=True)
class Card:
    """Carte au sens oracle, indépendante de l'édition."""

    oracle_id: str
    name: str
    mana_cost: str | None
    cmc: float
    type_line: str | None
    oracle_text: str | None
    color_identity: list[str] = field(default_factory=list)
    legalities: dict[str, str] = field(default_factory=dict)
    layout: str | None = None


@dataclass(frozen=True)
class CardPrint:
    """Impression : une carte dans une édition et une langue données."""

    scryfall_id: str
    oracle_id: str
    lang: str
    printed_name: str | None
    set_code: str
    set_name: str | None
    collector_number: str | None
    rarity: str | None
    art_crop_url: str | None
    price_eur: float | None
    price_usd: float | None
    price_eur_foil: float | None
    price_usd_foil: float | None
    # Finitions réellement imprimées, telles que publiées par Scryfall :
    # « nonfoil », « foil », « etched ». Détermine ce que le sélecteur propose.
    finishes: list[str]
    released_at: str | None


def normalize_name(name: str) -> str:
    """Réduit un nom de carte à une forme comparable.

    Minuscules, accents retirés, apostrophes unifiées, espaces normalisés. C'est la
    clé de recherche utilisée par l'autocomplétion et par la résolution des decklists
    dont les noms viennent de sources hétérogènes.

    >>> normalize_name("Île")
    'ile'
    """
    unified = name
    for apostrophe in _APOSTROPHES:
        unified = unified.replace(apostrophe, "'")

    decomposed = unicodedata.normalize("NFKD", unified)
    without_accents = "".join(c for c in decomposed if not unicodedata.combining(c))

    return " ".join(without_accents.lower().split())


def is_relevant(legalities: dict[str, str]) -> bool:
    """Vrai si la carte est légale dans au moins un format couvert.

    « banned » et « restricted » ne comptent pas : seule la valeur « legal » ouvre
    la porte.
    """
    return any(legalities.get(fmt) == "legal" for fmt in RELEVANT_FORMATS)


def _as_float(value: Any) -> float | None:
    """Convertit un prix Scryfall (chaîne ou None) en flottant."""
    if value is None or value == "":
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _art_crop_url(payload: dict[str, Any]) -> str | None:
    """Trouve l'illustration, à la racine ou sur la première face qui en porte une."""
    root = payload.get("image_uris") or {}
    if root.get("art_crop"):
        return root["art_crop"]

    for face in payload.get("card_faces") or []:
        uris = face.get("image_uris") or {}
        if uris.get("art_crop"):
            return uris["art_crop"]

    return None


def parse_card(payload: dict[str, Any]) -> Card:
    """Construit la carte oracle à partir d'un payload Scryfall.

    Le payload peut être une impression localisée : on retient malgré tout le nom
    oracle anglais du champ `name`.
    """
    oracle_id = payload.get("oracle_id")
    if not oracle_id:
        raise ValueError(f"payload Scryfall sans oracle_id : {payload.get('name')!r}")

    return Card(
        oracle_id=oracle_id,
        name=payload["name"],
        mana_cost=payload.get("mana_cost"),
        cmc=float(payload.get("cmc") or 0),
        type_line=payload.get("type_line"),
        oracle_text=payload.get("oracle_text"),
        color_identity=list(payload.get("color_identity") or []),
        legalities=dict(payload.get("legalities") or {}),
        layout=payload.get("layout"),
    )


def parse_print(payload: dict[str, Any]) -> CardPrint:
    """Construit l'impression à partir d'un payload Scryfall.

    **Les deux cotes sont conservées séparément.** Une impression brillante se
    vend couramment le double ou le triple de sa jumelle normale ; les mélanger
    fausse la valorisation dans les deux sens. Le repli de l'une sur l'autre
    reste possible, mais il appartient à la base de le décider au moment de
    l'affichage, pas à l'ingestion de l'imposer.

    Certaines impressions n'existent qu'en brillant — bundles, Secret Lair,
    promotions. `finishes` le dit, pour que le sélecteur ne propose pas une
    finition qui n'a jamais été imprimée.
    """
    prices = payload.get("prices") or {}

    return CardPrint(
        scryfall_id=payload["id"],
        oracle_id=payload["oracle_id"],
        lang=payload.get("lang") or "en",
        printed_name=payload.get("printed_name"),
        set_code=payload["set"],
        set_name=payload.get("set_name"),
        collector_number=payload.get("collector_number"),
        rarity=payload.get("rarity"),
        art_crop_url=_art_crop_url(payload),
        price_eur=_as_float(prices.get("eur")),
        price_usd=_as_float(prices.get("usd")),
        price_eur_foil=_as_float(prices.get("eur_foil")),
        price_usd_foil=_as_float(prices.get("usd_foil")),
        finishes=payload.get("finishes") or [],
        released_at=payload.get("released_at"),
    )


def search_names_for(payload: dict[str, Any]) -> list[tuple[str, str, str]]:
    """Produit les entrées d'index de recherche d'une impression.

    Renvoie des triplets `(nom affiché, nom normalisé, langue)`. Une impression
    française en génère deux — le nom oracle anglais et le nom imprimé — pour que la
    saisie fonctionne dans les deux langues. Les doublons sont écartés.

    **Chaque face est indexée séparément.** Le catalogue nomme une carte
    recto-verso « Delver of Secrets // Insectile Aberration », mais les decklists
    et les joueurs disent « Delver of Secrets ». Sans entrée par face, la
    résolution des decklists échoue et la recherche par égalité ne trouve rien.
    """
    lang = payload.get("lang") or "en"
    entries: list[tuple[str, str, str]] = []
    seen: set[str] = set()

    candidates = [(payload["name"], "en")]
    printed = payload.get("printed_name")
    if printed:
        candidates.append((printed, lang))

    for face in payload.get("card_faces") or []:
        face_name = face.get("name")
        if face_name:
            candidates.append((face_name, "en"))
        face_printed = face.get("printed_name")
        if face_printed:
            candidates.append((face_printed, lang))

    for display, entry_lang in candidates:
        normalized = normalize_name(display)
        if normalized in seen:
            continue
        seen.add(normalized)
        entries.append((display, normalized, entry_lang))

    return entries
