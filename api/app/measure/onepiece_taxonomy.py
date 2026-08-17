"""Banc : de quoi le catalogue One Piece est-il fait, et par quel champ le dire.

Septième jeu envisagé, et les six précédents ont chacun laissé une leçon que ce
banc applique avant la première écriture : Riftbound a dérivé son identité de
champs d'affichage que la source réécrivait, Yu-Gi-Oh a rangé son Attribut dans
`color_identity`, Pokémon a cru devoir s'appuyer sur `rarity`, Wankul a fusionné
15 cartes sur 958, SWU a failli compter ses finitions pour des impressions.

Cinq questions, dans l'ordre où elles bloquent la suite :

1. **Le périmètre.** Le catalogue se lit par **deux portes** — les extensions et
   les decks de démarrage —, et l'oublier en couperait un huitième. Que reste-t-il
   dehors malgré les deux ?
2. **L'identité.** 3 485 entrées pour 2 255 codes dans les seules extensions :
   les illustrations alternatives partagent le code de leur carte. Quelle clé
   désigne la *carte*, laquelle désigne l'*impression*, et la règle tient-elle
   dans les deux sens ?
3. **Les maquettes.** Quatre types — `Character`, `Event`, `Leader`, `Stage`.
   Combien de fenêtres d'illustration cela fera-t-il ?
4. **Le chaînage vers les prix.** Cette source ne publie aucun identifiant
   TCGplayer : le rapprochement se fera par extension et numéro, comme pour
   Yu-Gi-Oh et Pokémon. Le code est-il assez propre pour ça ?
5. **Les homonymes.** 433 noms sont portés par plusieurs entrées. Combien
   désignent des cartes réellement différentes, que seule l'illustration
   sépare — le cas Riftbound et ses 80 homonymes ?

**Ce banc n'écrit rien en base.**

Usage :
    cd api && .venv/Scripts/python -m app.measure.onepiece_taxonomy
"""

from __future__ import annotations

import re
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass

from app.measure.optcgapi_probe import Probe, ProbeError

#: Suffixes qu'ajoute la source au nom d'une illustration alternative :
#: « Perona (Box Topper) » pour la même carte que « Perona ». C'est le motif
#: exact de Riftbound, dont les 243 variantes suffixées créaient deux lignes de
#: collection pour un seul exemplaire.
#:
#: **Ils s'empilent, et n'en retirer qu'un fait conclure à tort.** Une première
#: version s'arrêtait au dernier suffixe, et le banc annonçait alors « 316 codes
#: réunissent deux cartes différentes » — alors que « Donquixote Doflamingo
#: (073) », « … (073) (Parallel) » et « … (SP) » sont la même carte sous trois
#: tirages. Le `+` à la fin les retire tous.
VARIANT_SUFFIX = re.compile(r"(\s*\([^)]*\))+\s*$")

#: Second motif de suffixe : le code accolé par un tiret entouré d'espaces —
#: « Buggy - OP03-008 (Pirate Foil) ». Il se retire **avant** les parenthèses.
#:
#: **Les espaces autour du tiret sont ce qui protège les noms**, et ce n'est pas
#: cosmétique : « Zoro-Juurou », « Eustass"Captain"Kid » et bien d'autres portent
#: un tiret dans leur nom. Un motif plus lâche les amputerait.
VARIANT_CODE_SUFFIX = re.compile(r"\s+-\s+[A-Z]{1,4}\d*-\d+\s*$")

#: Ce qui sépare une illustration alternative de sa carte dans `card_image_id` :
#: `OP01-077_p1` contre `OP01-077`.
#:
#: **Deux lettres, pas une**, et la seconde s'est fait oublier. Une première
#: version ne lisait que `_p`, et manquait **335 variantes** en `_r` — le
#: vocabulaire complet, relevé sur les 3 992 entrées, va de `p1` à `p8` et de
#: `r1` à `r3`. Le symptôme n'était pas une erreur mais un chiffre légèrement
#: trop bon : la pile des Personnages contenait une variante, et sa paire la
#: plus serrée tombait pile sur le seuil de confiance.
PRINT_SUFFIX = re.compile(r"_[a-z]\d+$")


@dataclass(frozen=True)
class Entry:
    """Une entrée du catalogue, telle que la source la publie."""

    origin: str  # extension ou deck de démarrage
    code: str  # `card_set_id`, ex. OP01-077
    image_id: str  # `card_image_id`, ex. OP01-077_p1
    name: str
    type: str
    color: str
    cost: str
    rarity: str
    text: str
    image: str

    @property
    def base_name(self) -> str:
        """Le nom sans ses suffixes de variante.

        Deux passes, dans cet ordre : les parenthèses d'abord — elles peuvent
        suivre le code —, puis le code accolé par tiret, puis les parenthèses à
        nouveau, un nom pouvant porter les deux dans n'importe quel ordre
        (« Sabo (Alternate Art) (Manga) », « Sanji - OP06-119 (Reprint) »).
        """
        name = VARIANT_SUFFIX.sub("", self.name).strip()
        name = VARIANT_CODE_SUFFIX.sub("", name).strip()
        return VARIANT_SUFFIX.sub("", name).strip()

    @property
    def is_variant(self) -> bool:
        return bool(PRINT_SUFFIX.search(self.image_id or ""))


def parse(row: dict, origin: str) -> Entry:
    return Entry(
        origin=origin,
        code=(row.get("card_set_id") or "").strip(),
        image_id=(row.get("card_image_id") or "").strip(),
        name=(row.get("card_name") or "").strip(),
        type=(row.get("card_type") or "").strip(),
        color=(row.get("card_color") or "").strip(),
        cost=str(row.get("card_cost") or ""),
        rarity=(row.get("rarity") or "").strip(),
        text=(row.get("card_text") or "").strip(),
        image=(row.get("card_image") or "").strip(),
    )


def load(probe: Probe) -> tuple[list[Entry], list[str]]:
    """Les deux parcours, et les origines injoignables."""
    entries: list[Entry] = []
    unreachable: list[str] = []

    sets = probe.set_ids()
    decks = probe.deck_ids()
    print(f"{len(sets)} extensions et {len(decks)} decks de démarrage")

    for code in sets:
        try:
            entries.extend(parse(row, code) for row in probe.cards(code))
        except ProbeError as exc:
            print(f"  extension {code} injoignable : {exc}")
            unreachable.append(code)
    for code in decks:
        try:
            entries.extend(parse(row, code) for row in probe.deck_cards(code))
        except ProbeError as exc:
            print(f"  deck {code} injoignable : {exc}")
            unreachable.append(code)
    return entries, unreachable


def report_scope(entries: list[Entry], unreachable: list[str]) -> None:
    """1. Le périmètre : ce que les deux portes rapportent, et ce qui manque."""
    print("\n=== 1. périmètre : deux portes, pas une ===")
    par_origine = Counter(e.origin for e in entries)
    boosters = {o: n for o, n in par_origine.items() if not o.startswith("ST")}
    starters = {o: n for o, n in par_origine.items() if o.startswith("ST")}
    print(f"  extensions          : {sum(boosters.values()):>5} entrées "
          f"sur {len(boosters)} origines")
    print(f"  decks de démarrage  : {sum(starters.values()):>5} entrées "
          f"sur {len(starters)} origines")
    print(f"  total               : {len(entries):>5}")
    if unreachable:
        print(f"  INJOIGNABLES        : {', '.join(unreachable)}")

    # Ce que les starters apportent et que les extensions n'ont pas : c'est la
    # mesure qui dit si le second parcours valait la peine.
    codes_boosters = {e.code for e in entries if not e.origin.startswith("ST")}
    codes_starters = {e.code for e in entries if e.origin.startswith("ST")}
    propres = codes_starters - codes_boosters
    print(f"  codes que seuls les starters apportent : {len(propres)}")

    sans_code = [e for e in entries if not e.code]
    sans_image = [e for e in entries if not e.image]
    print(f"  entrées sans code      : {len(sans_code)}")
    print(f"  entrées sans rendu     : {len(sans_image)}")


def report_identity(entries: list[Entry]) -> None:
    """2. L'identité : la carte, l'impression, et la règle dans les deux sens.

    Vérifiée **dans les deux sens**, seul contrôle qui vaille pour une règle
    d'identité : ce qu'elle réunit et ce qu'elle sépare. Une règle vérifiée dans
    un seul sens laisse passer la fusion silencieuse — celle qui a coûté #29.
    """
    print("\n=== 2. identité : le code désigne la carte, l'image l'impression ===")
    par_code = defaultdict(list)
    for e in entries:
        par_code[e.code].append(e)
    par_image = defaultdict(list)
    for e in entries:
        par_image[e.image_id].append(e)

    print(f"  entrées                  : {len(entries):>5}")
    print(f"  codes distincts (cartes) : {len(par_code):>5}")
    print(f"  `card_image_id` distincts: {len(par_image):>5}")

    collisions = {k: v for k, v in par_image.items() if len(v) > 1}
    print(f"  `card_image_id` porté par plusieurs entrées : {len(collisions)}")
    for key, group in list(collisions.items())[:4]:
        print(f"      {key} : {[e.origin for e in group]}")

    # Le sens qui compte : sous un même code, les entrées désignent-elles bien
    # la même carte ? Si leur nom de base ou leur type diffère, la clé est
    # trop grossière et fusionnerait deux cartes.
    melanges = [
        (k, v) for k, v in par_code.items()
        if len({e.base_name for e in v}) > 1 or len({e.type for e in v}) > 1
    ]
    print(f"\n--- un même code réunit-il deux cartes différentes ? ---")
    print(f"  codes dont les entrées divergent : {len(melanges)}")
    for code, group in melanges[:5]:
        print(f"      {code} : {sorted({e.name for e in group})}")

    # Et l'autre sens : les variantes se reconnaissent-elles ?
    variantes = [e for e in entries if e.is_variant]
    suffixes = [e for e in entries if e.name != e.base_name]
    print(f"\n--- les illustrations alternatives ---")
    print(f"  marquées dans `card_image_id` (`_p1`) : {len(variantes)}")
    print(f"  marquées par un suffixe de nom        : {len(suffixes)}")
    accord = sum(1 for e in entries if e.is_variant == (e.name != e.base_name))
    print(f"  les deux marques concordent sur       : {accord} / {len(entries)}")
    for e in [x for x in entries if x.is_variant != (x.name != x.base_name)][:5]:
        print(f"      {e.code:<12} image={e.image_id:<16} nom={e.name}")


def report_layouts(entries: list[Entry]) -> None:
    """3. Les maquettes : combien de fenêtres d'illustration ?"""
    print("\n=== 3. types, et ce qu'ils annoncent de maquettes ===")
    for value, n in Counter(e.type for e in entries).most_common():
        variantes = sum(1 for e in entries if e.type == value and e.is_variant)
        print(f"  {value or '(vide)':<14} {n:>5} entrées, dont {variantes} variantes")

    # Le coût : porté par toutes les cartes ? Un Leader n'en a pas, il a un
    # coût de vie. C'est ce qui décidera si une courbe a du sens.
    sans_cout = Counter(e.type for e in entries if not e.cost or e.cost == "None")
    print(f"\n--- entrées sans coût, par type ---")
    for value, n in sans_cout.most_common():
        print(f"      {value:<14} {n:>5}")


def report_price_link(entries: list[Entry]) -> None:
    """4. Le chaînage vers les prix : le code est-il exploitable ?

    Cette source ne publie **aucun identifiant TCGplayer**, contrairement à
    Riftcodex et SWU-DB. Le rapprochement passera donc par extension et numéro,
    comme pour Yu-Gi-Oh — dont le catalogue écrit `LOB-EN005` là où TCGplayer
    écrit `LOB-005`, si bien que sans normalisation **aucune** carte n'aurait
    été cotée, et l'échec aurait été muet.
    """
    print("\n=== 4. chaînage vers les prix ===")
    formes = Counter()
    for e in entries:
        formes[_shape(e.code)] += 1
    print("  silhouettes de code observées :")
    for shape, n in formes.most_common(6):
        exemple = next(e.code for e in entries if _shape(e.code) == shape)
        print(f"      {shape:<16} {n:>5}  ex. {exemple}")

    # L'extension se lit-elle dans le code ? C'est elle qu'il faudra rapprocher
    # du groupe TCGplayer.
    prefixes = {e.code.split("-")[0] for e in entries if "-" in e.code}
    print(f"  préfixes d'extension distincts : {len(prefixes)}")
    ecarts = [e for e in entries if "-" in e.code
              and e.code.split("-")[0].rstrip("0123456789") not in ("OP", "ST", "EB", "PRB")]
    print(f"  codes dont le préfixe sort du vocabulaire attendu : {len(ecarts)}")
    for e in ecarts[:5]:
        print(f"      {e.code} ({e.origin})")


def _shape(code: str) -> str:
    """Silhouette d'un code : chiffres, lettres et ponctuation, sans la valeur."""
    out: list[str] = []
    for char in code:
        kind = "9" if char.isdigit() else ("A" if char.isalpha() else char)
        if not out or out[-1] != kind:
            out.append(kind)
    return "".join(out)


def report_homonyms(entries: list[Entry]) -> None:
    """5. Les homonymes : combien de cartes réellement différentes ?

    Riftbound en compte 80 que seule l'illustration sépare, ce qui a décidé de
    faire primer l'empreinte sur le nom pour ce jeu. La question se repose ici,
    et sa réponse décidera de la même chose.
    """
    print("\n=== 5. homonymes ===")
    par_nom = defaultdict(set)
    for e in entries:
        par_nom[e.base_name].add(e.code)
    partages = {n: c for n, c in par_nom.items() if len(c) > 1}
    print(f"  noms de base distincts          : {len(par_nom)}")
    print(f"  portés par plusieurs cartes     : {len(partages)}")
    for nom, codes in sorted(partages.items(), key=lambda kv: -len(kv[1]))[:6]:
        print(f"      {nom[:34]:<36} {len(codes)} cartes : {sorted(codes)[:4]}")

    # Ce qui décide vraiment : ces homonymes se distinguent-ils autrement que
    # par l'illustration ? Si leur type ou leur couleur diffère, un filtre
    # suffit ; sinon, seule l'empreinte les sépare.
    par_code = {e.code: e for e in entries}
    separables = 0
    for codes in partages.values():
        vus = [par_code[c] for c in codes if c in par_code]
        if len({(e.type, e.color, e.cost) for e in vus}) == len(vus):
            separables += 1
    print(f"  dont séparables par type, couleur et coût : {separables} / {len(partages)}")


def run() -> None:
    probe = Probe()
    entries, unreachable = load(probe)
    report_scope(entries, unreachable)
    report_identity(entries)
    report_layouts(entries)
    report_price_link(entries)
    report_homonyms(entries)
    print(f"\n{probe.requests} requêtes émises (le reste venait du cache)")


if __name__ == "__main__":
    try:
        run()
    except KeyboardInterrupt:
        sys.exit("interrompu")
