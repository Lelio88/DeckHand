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
    collector_number: str
    page: int
    slot: int
    copies: int
    has_foil: bool

    @classmethod
    def from_row(cls, row: dict[str, object]) -> Location:
        return cls(
            name=str(row.get("name") or ""),
            matched_name=str(row.get("matched_name") or row.get("name") or ""),
            set_name=str(row.get("set_name") or ""),
            collector_number=str(row.get("collector_number") or ""),
            page=int(row.get("page") or 0),
            slot=int(row.get("slot") or 0),
            copies=int(row.get("copies") or 0),
            has_foil=bool(row.get("has_foil")),
        )


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


def _one_place(place: Location) -> str:
    number = f"#{place.collector_number}" if place.collector_number else ""
    where = f"{place.set_name} {number}".strip()
    copies = f"×{place.copies}" if place.copies > 1 else ""
    marks = ", ".join(part for part in (copies, "brillante" if place.has_foil else "") if part)
    suffix = f" ({marks})" if marks else ""
    return f"{where}, page {place.page} case {place.slot}{suffix}"


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
