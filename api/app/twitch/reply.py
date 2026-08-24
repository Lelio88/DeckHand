"""La phrase rendue au chat — logique pure, testable sans réseau.

**Une localisation, pas un oui/non.** « oui » n'apprend rien à qui va chercher
la carte ; « Marvel Super Heroes #412, page 46, case 5 » lui évite de feuilleter
le classeur. C'est ce que le modèle par édition rend gratuit.

**L'absence et le silence se disent pareil.** Une carte non possédée, une
adresse qui ne mène nulle part, une extension retirée du partage : la même
phrase. Distinguer confirmerait l'existence d'une collection fermée à qui essaie
des noms au hasard — l'anti-énumération vaut ici comme côté base.

**Trois emplacements au plus.** Un chat lit une ligne, pas un tableau ; et un
terrain de base occupe une douzaine de cases à lui seul. Ce qui déborde est
compté, jamais tronqué en silence.
"""

from __future__ import annotations

from dataclasses import dataclass

# Au-delà, la phrase cesse d'être lisible dans un chat qui défile.
MAX_PLACES = 3


@dataclass(frozen=True)
class Location:
    """Une case du classeur, telle que `binder_locate` la rend."""

    name: str
    matched_name: str
    set_name: str
    #: Code de l'extension. `set_name` sert à l'affichage ; celui-ci est la clé
    #: de la case, celle que la désignation envoie à la base.
    set_code: str
    collector_number: str
    page: int
    slot: int
    copies: int
    has_foil: bool
    #: Cote de la case, ou `None` quand la carte n'en a pas.
    #:
    #: **L'absence de cote n'est pas un prix nul.** Beaucoup d'impressions
    #: françaises n'en portent aucune ; annoncer « 0,00 € » ferait croire à une
    #: carte sans valeur là où l'on ne sait simplement pas.
    price_eur: float | None = None

    @classmethod
    def from_row(cls, row: dict[str, object]) -> Location:
        prix = row.get("price_eur")
        return cls(
            name=str(row.get("name") or ""),
            matched_name=str(row.get("matched_name") or row.get("name") or ""),
            set_name=str(row.get("set_name") or ""),
            set_code=str(row.get("set_code") or ""),
            collector_number=str(row.get("collector_number") or ""),
            page=int(row.get("page") or 0),
            slot=int(row.get("slot") or 0),
            copies=int(row.get("copies") or 0),
            has_foil=bool(row.get("has_foil")),
            price_eur=float(prix) if prix is not None else None,
        )


@dataclass(frozen=True)
class Addition:
    """Une carte récemment entrée au classeur, telle que
    `public_recent_additions` la rend."""

    name: str
    printed_name: str
    set_code: str
    collector_number: str

    @classmethod
    def from_row(cls, row: dict[str, object]) -> Addition:
        return cls(
            name=str(row.get("name") or ""),
            printed_name=str(row.get("printed_name") or row.get("name") or ""),
            set_code=str(row.get("set_code") or ""),
            collector_number=str(row.get("collector_number") or ""),
        )


@dataclass(frozen=True)
class Shelf:
    """Une extension du rayonnage, telle que `public_binder_shelf` la rend."""

    set_code: str
    set_name: str
    total_cells: int
    owned_cells: int

    @classmethod
    def from_row(cls, row: dict[str, object]) -> Shelf:
        return cls(
            set_code=str(row.get("set_code") or ""),
            set_name=str(row.get("set_name") or row.get("set_code") or ""),
            total_cells=int(row.get("total_cells") or 0),
            owned_cells=int(row.get("owned_cells") or 0),
        )


def format_recent(additions: list[Addition]) -> str:
    """Les dernières cartes entrées au classeur.

    **La commande du direct.** Un spectateur qui arrive en cours de route
    rattrape en une ligne ce qui vient d'être ouvert — et cela n'a de sens que
    parce que les cartes sont scannées au fur et à mesure.

    Le nom **imprimé** prime sur le nom oracle : c'est celui qu'on vient de voir
    à l'écran, et répondre « Island » à qui a vu « Île » donnerait l'impression
    d'une autre carte.
    """
    if not additions:
        return "rien d'ajouté pour l'instant."
    shown = additions[:MAX_PLACES]
    rest = len(additions) - len(shown)
    tail = f" (+{rest} autre{'s' if rest > 1 else ''})" if rest > 0 else ""
    return (
        "ajoutées récemment : "
        + " · ".join(_one_addition(a) for a in shown)
        + tail
    )


def _one_addition(addition: Addition) -> str:
    nom = addition.printed_name or addition.name
    ou = " ".join(
        part
        for part in (addition.set_code.upper(), addition.collector_number)
        if part
    )
    return f"{nom} ({ou})" if ou else nom


def format_shelf(shelves: list[Shelf]) -> str:
    """L'avancement du classeur, extension par extension.

    **Borné par nature**, contrairement à une liste de cartes : on possède une
    poignée d'extensions, pas des centaines. Ce qui déborde est compté.

    Les extensions non partagées n'apparaissent pas — non par filtrage ici, mais
    parce que la base ne les rend pas. Un « 0/453 » révélerait qu'elles existent
    et qu'on a choisi de les cacher.
    """
    if not shelves:
        return "classeur vide, ou pas encore partagé."
    shown = shelves[:MAX_PLACES]
    rest = len(shelves) - len(shown)
    parts = [f"{s.set_name} {s.owned_cells}/{s.total_cells}" for s in shown]
    tail = f" (+{rest} autre{'s' if rest > 1 else ''})" if rest > 0 else ""
    return "classeur : " + " · ".join(parts) + tail


def format_reply(query: str, locations: list[Location]) -> str:
    """Ce que le bot écrit dans le chat pour cette recherche."""
    if not locations:
        return f"« {query.strip()} » : pas dans le classeur."

    # Le nom affiché est celui du catalogue dans la langue trouvée : demander
    # « ile » et s'entendre répondre « Island » donnerait l'impression d'une
    # autre carte.
    head = locations[0].matched_name or locations[0].name
    shown = locations[:MAX_PLACES]
    rest = len(locations) - len(shown)

    parts = [_one_place(place) for place in shown]
    tail = f" (+{rest} autre{'s' if rest > 1 else ''})" if rest > 0 else ""
    return f"{head} — " + " · ".join(parts) + tail


def format_spotlight(place: Location, accepte: bool) -> str:
    """Ce que le bot répond à `!montre`.

    **Trois issues, et une seule est un succès.** La carte monte à l'écran ; ou
    l'écran vient d'être pris et il faut attendre ; ou la carte n'est pas dans le
    classeur — ce dernier cas ne passe jamais par ici, la commande renonçant
    avant d'écrire quoi que ce soit.

    Le refus **dit quoi faire**, contrairement à un refus de débit qui, lui, est
    un silence. La différence tient à ce que le spectateur a déjà obtenu une
    réponse : sa commande a été acceptée, la recherche a eu lieu, et se taire
    laisserait croire à une panne.
    """
    if not accepte:
        return "l'écran est déjà pris — réessaie dans un instant."
    ou = f"{place.set_name} #{place.collector_number}".strip()
    return f"{place.matched_name or place.name} à l'écran — {ou}."


def format_prix(euros: float | None) -> str:
    """Une cote, à la française — ou rien du tout.

    **Rien plutôt que zéro.** Une impression sans cote n'est pas une carte sans
    valeur : Scryfall ne cote pratiquement que l'anglais, et la plupart des
    impressions françaises n'en portent aucune. « 0,00 € » serait un mensonge
    là où le silence est exact.
    """
    if euros is None:
        return ""
    return f"{euros:.2f} €".replace(".", ",")


def _one_place(place: Location) -> str:
    number = f"#{place.collector_number}" if place.collector_number else ""
    where = f"{place.set_name} {number}".strip()
    copies = f"×{place.copies}" if place.copies > 1 else ""
    marks = ", ".join(
        part
        for part in (
            copies,
            "brillante" if place.has_foil else "",
            format_prix(place.price_eur),
        )
        if part
    )
    suffix = f" ({marks})" if marks else ""
    return f"{where}, page {place.page} case {place.slot}{suffix}"


@dataclass(frozen=True)
class Cell:
    """Une case d'une page, telle que `public_binder_page` la rend."""

    collector_number: str
    name: str
    owned: int

    @classmethod
    def from_row(cls, row: dict[str, object]) -> Cell:
        return cls(
            collector_number=str(row.get("collector_number") or ""),
            name=str(row.get("printed_name") or row.get("name") or ""),
            owned=int(row.get("owned") or 0),
        )


def format_page(set_code: str, page: int, cells: list[Cell]) -> str:
    """Ce qu'une page de classeur donne en une ligne.

    **Pas les neuf noms.** Une page ne se récite pas dans un chat. On compte les
    cases pleines et on **nomme les vides par leur numéro** — ce qui tient
    précisément parce qu'une page en compte neuf au plus.

    C'est la question « qu'est-ce qui te manque » ramenée à une échelle où elle a
    une réponse : sur une extension entière il manque des centaines de cases, et
    aucune troncature n'en fait une phrase utile.
    """
    if not cells:
        return f"rien à la page {page} de « {set_code} »."
    pleines = sum(1 for cell in cells if cell.owned)
    vides = [cell.collector_number for cell in cells if not cell.owned]
    tete = f"{set_code.upper()} page {page} : {pleines}/{len(cells)} cases"
    if not vides:
        return f"{tete} — complète."
    return f"{tete} — manquent " + ", ".join(f"#{n}" for n in vides) + "."


def parse_page_command(text: str, prefix: str = "!page") -> tuple[str, int] | None:
    """L'extension et la page demandées, ou `None`.

    **Deux arguments dont un seul est obligatoire.** `!page msh` répond sur la
    première page : exiger le numéro ferait échouer la forme la plus naturelle.
    Un second mot qui n'est pas un nombre fait en revanche renoncer — répondre
    sur la page 1 à `!page msh bidule` inventerait une question.
    """
    argument = parse_command(text, prefix)
    if argument is None:
        return None
    mots = argument.split()
    if not mots:
        return None
    if len(mots) == 1:
        return mots[0], 1
    if len(mots) == 2 and mots[1].isdigit() and int(mots[1]) > 0:
        return mots[0], int(mots[1])
    return None


def parse_bare_command(text: str, name: str) -> bool:
    """Vrai si ce message **est** cette commande, sans argument.

    **Un jumeau de `parse_command`, et pas son extension.** Celle-ci exige un
    argument, à dessein : `!card` seul ne veut rien dire. Les commandes sans
    argument ont le besoin exactement inverse — `!classeur toto` ne doit rien
    déclencher, sans quoi n'importe quelle phrase commençant par le mot
    répondrait.
    """
    return text.strip().lower() == name.lower()


def parse_command(text: str, prefix: str = "!card") -> str | None:
    """La recherche portée par ce message, ou `None` si ce n'en est pas une.

    La comparaison est insensible à la casse et tolère les espaces de tête que
    les clients de chat laissent traîner. Une commande sans argument ne
    déclenche rien : répondre « pas dans le classeur » à `!card` seul serait
    faux, et inviter à la syntaxe encouragerait à la répéter.
    """
    stripped = text.strip()
    lowered = stripped.lower()
    if not lowered.startswith(prefix.lower()):
        return None

    rest = stripped[len(prefix) :]
    # Sans séparateur, `!cards` déclencherait la commande `!card`.
    if rest and not rest[0].isspace():
        return None

    query = rest.strip()
    return query or None
