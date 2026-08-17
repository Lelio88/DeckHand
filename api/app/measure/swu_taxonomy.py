"""Banc : de quoi le catalogue Star Wars Unlimited est-il fait, et par quel champ le dire.

**La question n'est pas « combien de cartes » mais « quelle règle tient ».**
Quatre jeux ont été accueillis avant celui-ci, et chacun a payé une hypothèse
non mesurée : Riftbound a dérivé son identité de champs d'affichage que la
source réécrivait (#29, 1 035 cartes ramenées à 929), Yu-Gi-Oh a rangé son
Attribut dans `color_identity` et s'est vu écarter 32 % de son catalogue par une
règle qui n'existe pas, Pokémon a cru devoir s'appuyer sur `rarity` et a trouvé
cinq champs mieux faits, Wankul a fusionné 15 cartes sur 958 parce que
`extension:numéro` n'était pas une identité. Ce banc pose les mêmes questions à
SWU **avant** la première écriture, là où leurs équivalents ont coûté une
réingestion complète.

Cinq questions, dans l'ordre où elles bloquent la suite :

1. **Le périmètre.** Les 38 extensions publiées mêlent le jeu, ses promos, ses
   exclusivités de convention et ses **jetons**, qui ne se jouent pas et
   n'entrent dans aucun deck. Quel champ les sépare — un type structuré, ou un
   nom d'extension à parser ?
2. **L'identité.** `/cards/sor` rend 946 entrées quand `/sets` en annonce 252 :
   les variantes sont des impressions. Quelle clé désigne la *carte*, et
   survit-elle aux réimpressions d'une extension à l'autre ?
3. **Les maquettes.** `Type` est un vocabulaire fermé de cinq valeurs, et
   `DoubleSided` en marque une. Reste ce qu'aucun champ ne dit : **quelles
   cartes sont imprimées en travers**. Wankul a montré qu'un champ déclaré ne
   répond pas à cette question — seule l'image y répond.
4. **Le chaînage vers les prix.** Riftbound laisse 227 impressions sans cote
   faute de `tcgplayer_id` chez sa source. Combien SWU en perdrait-il ?
5. **Les finitions.** Le défaut du § 6 de l'annexe multi-jeu — quatre jeux
   incapables de déclarer une carte brillante — s'est réglé jeu par jeu, chacun
   avec sa propre source de vérité. Où SWU déclare-t-il la sienne ?

**Ce banc n'écrit rien en base.** Il ne lit que la structure, sauf pour la
question 3, qui exige de regarder des images : un échantillon par type suffit à
dire l'orientation, et c'est elle qui décide du nombre de gabarits — donc du
coût de `swu_art_window`.

Usage :
    cd api && .venv/Scripts/python -m app.measure.swu_taxonomy
    #   --sample N   images regardées par type pour l'orientation (défaut 6)
"""

from __future__ import annotations

import argparse
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass
from typing import Any

from PIL import Image

from app.measure.swu_probe import Probe, ProbeError

#: Préfixe des types qui ne se jouent pas. Les jetons sont créés par une carte
#: en cours de partie ; ils n'entrent dans aucune liste, ne se collectionnent
#: pas en vue d'un deck, et Magic en donne le précédent — les 22 jetons possédés
#: par le propriétaire ne sont légaux dans aucun format construit.
#:
#: Le préfixe est lu sur le **type**, non sur le nom de l'extension : « Tokens »
#: y figure pour TSOR et TASH, mais un nom d'extension est un libellé
#: d'affichage, que rien n'oblige à rester stable. Le banc vérifie que les deux
#: désignent bien le même ensemble.
TOKEN_TYPE_PREFIX = "Token"

#: Le suffixe qui, dans `VariantType`, marque une finition brillante.
#:
#: **Ce champ porte deux choses à la fois**, et les confondre fausse tout : un
#: *traitement d'impression* (`Normal`, `Hyperspace`, `Showcase`, `Prestige`,
#: `OP Promo`…) et une *finition* (le suffixe ` Foil`). Mesuré sur les 61
#: valeurs du catalogue : `Hyperspace` et `Hyperspace Foil` sont la même
#: impression dans deux finitions — elles partagent leur `tcgplayerId`, ce qui
#: est la preuve que TCGplayer n'y voit qu'un seul produit.
#:
#: La conséquence pour le modèle est directe : **une entrée « X Foil » n'est pas
#: une impression de plus**, c'est la case brillante de l'impression « X ». Les
#: compter séparément gonflerait `card_prints` de moitié et ferait apparaître
#: deux lignes de collection pour un seul exemplaire — le défaut exact que
#: Riftbound a payé sur ses 243 variantes suffixées.
#: **Le traitement de base rompt la règle du suffixe**, et c'est le piège de ce
#: champ : la version brillante de `Normal` ne s'appelle pas « Normal Foil »
#: mais `Foil` tout court. Lire un suffixe et rien d'autre classerait ces
#: 1 148 impressions parmi les ordinaires — la moitié du catalogue courant —, et
#: le rapport aurait annoncé « aucune brillante en traitement standard » avec
#: l'assurance d'une mesure. Un test le verrouille.
FOIL_MARKER = " Foil"
FOIL_ALONE = "Foil"
BASE_TREATMENT = "Normal"


@dataclass(frozen=True)
class Print:
    """Une impression, telle que la source la publie."""

    set_code: str
    number: str
    name: str
    subtitle: str
    type: str
    variant: str
    cid: str
    rarity: str
    double_sided: bool
    tcgplayer_id: str
    front_art: str
    foil_price: str

    @property
    def card_key(self) -> tuple[str, str]:
        """La carte que cette impression représente, par son titre imprimé."""
        return (self.name, self.subtitle)

    @property
    def is_token(self) -> bool:
        return self.type.startswith(TOKEN_TYPE_PREFIX)

    @property
    def is_foil(self) -> bool:
        return self.variant == FOIL_ALONE or self.variant.endswith(FOIL_MARKER)

    @property
    def treatment(self) -> str:
        """Le traitement d'impression, finition retirée.

        `Hyperspace Foil` et `Hyperspace` rendent tous deux `Hyperspace` : c'est
        la même impression, et c'est elle qui deviendra une ligne de
        `card_prints`. `Foil` seul rend `Normal`, la source ayant nommé le
        traitement de base autrement que sa finition brillante.
        """
        if self.variant == FOIL_ALONE:
            return BASE_TREATMENT
        if self.variant.endswith(FOIL_MARKER):
            return self.variant[: -len(FOIL_MARKER)]
        return self.variant


def load_catalogue(probe: Probe) -> tuple[list[dict[str, Any]], list[Print]]:
    """Toutes les impressions de toutes les extensions.

    Une requête par extension — trente-huit — et non une par carte. La liste
    d'une extension porte déjà chaque champ dont ce banc a besoin ; il n'existe
    d'ailleurs aucun endpoint qui rende le catalogue entier d'un coup.
    """
    sets = probe.sets()
    print(f"{len(sets)} extensions publiées")

    prints: list[Print] = []
    empty: list[str] = []
    unreachable: list[str] = []
    for index, entry in enumerate(sets, start=1):
        code = entry.get("setId") or ""
        if not code:
            continue
        try:
            rows = probe.cards(code)
        except ProbeError as exc:
            # Une extension injoignable n'est pas une extension vide, et les
            # confondre ferait passer un trou de mesure pour un fait du
            # catalogue. Elle est donc comptée à part et redite dans le rapport.
            print(f"  {code} : {exc}")
            unreachable.append(code)
            continue
        if not rows:
            empty.append(code)
            continue
        for row in rows:
            prints.append(
                Print(
                    set_code=row.get("Set") or code,
                    number=str(row.get("Number") or ""),
                    name=row.get("Name") or "",
                    subtitle=row.get("Subtitle") or "",
                    type=row.get("Type") or "",
                    variant=row.get("VariantType") or "",
                    cid=str(row.get("cid") or ""),
                    rarity=row.get("Rarity") or "",
                    double_sided=bool(row.get("DoubleSided")),
                    tcgplayer_id=str(row.get("tcgplayerId") or ""),
                    front_art=row.get("FrontArt") or "",
                    foil_price=str(row.get("FoilPrice") or ""),
                )
            )
        if index % 10 == 0:
            print(f"  {index}/{len(sets)} extensions, {len(prints)} impressions")

    if empty:
        print(f"  {len(empty)} extensions annoncées mais vides : {', '.join(empty)}")
    if unreachable:
        print(f"  {len(unreachable)} extensions INJOIGNABLES (mesure incomplète) : "
              f"{', '.join(unreachable)}")
    return sets, prints


def report_scope(prints: list[Print], sets: list[dict[str, Any]]) -> list[Print]:
    """1. Le périmètre : ce qui se joue, et ce qui ne se joue pas."""
    print("\n=== 1. périmètre : les jetons ne sont pas des cartes de deck ===")
    tokens = [p for p in prints if p.is_token]
    playable = [p for p in prints if not p.is_token]
    print(f"  catalogue entier : {len(prints):>6} impressions")
    print(f"  jetons (Type ~ « {TOKEN_TYPE_PREFIX}… ») : {len(tokens):>6}")
    for value, n in Counter(p.type for p in tokens).most_common():
        print(f"      {value:<20} {n:>4}")
    print(f"  reste, jouable   : {len(playable):>6} impressions")

    # Les deux désignations concordent-elles ? Un type est un vocabulaire ; un
    # nom d'extension est un libellé. Si le second déborde le premier, c'est le
    # premier qui a raison — mais il faut le savoir plutôt que le supposer.
    named_token_sets = {
        s["setId"] for s in sets if "token" in (s.get("fullName") or "").lower()
    }
    by_type = {p.set_code for p in tokens}
    print(f"\n--- le type et le nom d'extension disent-ils la même chose ? ---")
    print(f"  extensions dont le nom porte « Tokens » : {sorted(named_token_sets)}")
    print(f"  extensions où un type « Token… » apparaît : {sorted(by_type)}")
    strays = sorted(by_type - named_token_sets)
    hidden = sorted(named_token_sets - by_type)
    print(f"  jetons hors d'une extension de jetons   : {strays or 'aucun'}")
    print(f"  extensions de jetons sans type « Token »: {hidden or 'aucune'}")
    return playable


def report_identity(playable: list[Print]) -> None:
    """2. L'identité : qu'est-ce qui désigne une carte, et non une impression ?

    Vérifiée **dans les deux sens**, seul contrôle qui ait du sens pour une
    règle d'identité : ce qu'elle réunit (deux impressions d'une même carte
    tombent-elles bien sur la même clé ?) et ce qu'elle sépare (la clé ne
    réunit-elle *que* celles-là ?). Une règle vérifiée dans un seul sens laisse
    passer la fusion silencieuse, celle qui a coûté #29 à Riftbound.
    """
    print("\n=== 2. identité : la carte, l'impression, et ce qui les sépare ===")
    by_title = defaultdict(list)
    for p in playable:
        by_title[p.card_key].append(p)
    by_cid = defaultdict(list)
    for p in playable:
        by_cid[p.cid].append(p)

    print(f"  impressions jouables      : {len(playable):>6}")
    print(f"  titres distincts (nom + sous-titre) : {len(by_title):>6}")
    print(f"  `cid` distincts           : {len(by_cid):>6}")

    # `cid` ressemble à un identifiant de carte, et n'en est pas un — même
    # piège que le `riftbound_id` de #29, qui semblait désigner une carte et
    # regroupait en fait des centaines d'entrées sans rapport. S'il varie entre
    # deux impressions d'un même titre, il ne peut pas servir de clé d'oracle.
    cid_per_title = Counter(len({p.cid for p in group}) for group in by_title.values())
    print(f"\n--- `cid` : propriété de la carte, ou de l'impression ? ---")
    for distinct, n in sorted(cid_per_title.items()):
        print(f"      {n:>5} titres portent {distinct} `cid` distinct(s)")
    absent = sum(1 for p in playable if not p.cid)
    print(f"  impressions sans `cid` du tout : {absent}")

    # Une même carte réimprimée dans une autre extension : c'est le cas normal
    # des promos OP, et la clé doit le supporter sans créer une carte de plus.
    spread = {k: g for k, g in by_title.items() if len({p.set_code for p in g}) > 1}
    print(f"\n--- réimpressions d'une extension à l'autre ---")
    print(f"  titres présents dans plusieurs extensions : {len(spread)}")
    for key, group in list(sorted(spread.items(), key=lambda kv: -len(kv[1])))[:5]:
        sets_seen = sorted({p.set_code for p in group})
        label = f"{key[0]} — {key[1]}" if key[1] else key[0]
        print(f"      {label[:44]:<46} {len(group):>3} impr. dans {', '.join(sets_seen)}")

    # Le piège inverse : deux cartes réellement différentes sous un même titre.
    # Riftbound en compte 80, que seule l'illustration sépare. Ici, un titre
    # porté par deux types ou deux `cid` non liés serait le signal.
    ambiguous = {
        k: g for k, g in by_title.items() if len({p.type for p in g}) > 1
    }
    print(f"\n--- un même titre pour deux cartes différentes ? ---")
    print(f"  titres portés par plusieurs types : {len(ambiguous)}")
    for key, group in list(ambiguous.items())[:6]:
        label = f"{key[0]} — {key[1]}" if key[1] else key[0]
        print(f"      {label[:40]:<42} {sorted({p.type for p in group})}")

    # Et le numéro : identifie-t-il l'impression dans son extension ?
    collisions = 0
    per_set = defaultdict(Counter)
    for p in playable:
        per_set[p.set_code][p.number] += 1
    for code, numbers in per_set.items():
        collisions += sum(n - 1 for n in numbers.values() if n > 1)
    print(f"\n--- (extension, numéro) désigne-t-il une impression unique ? ---")
    print(f"  doublons sur tout le catalogue : {collisions}")


def report_layouts(playable: list[Print], probe: Probe, sample: int) -> None:
    """3. Les maquettes : combien de gabarits d'illustration faudra-t-il ?

    **L'orientation ne se lit pas sur un champ, elle se lit sur l'image.** La
    source ne publie rien qui la déclare — et quand bien même : Wankul publie
    un champ `orientation`, et il rend 40 cartes « horizontales » dont 13 sont
    imprimées debout. Ce qui tranche est le rapport largeur / hauteur du rendu.
    """
    print("\n=== 3. maquettes : types, faces, et orientation réelle ===")
    by_type = Counter(p.type for p in playable)
    for value, n in by_type.most_common():
        double = sum(1 for p in playable if p.type == value and p.double_sided)
        print(f"  {value:<12} {n:>5} impressions"
              f"{f'   dont {double} double-face' if double else ''}")

    # **Le type ne suffit pas, et c'est mesuré.** Une première passe regardait
    # six rendus par type et concluait « Base : 5/6 couchées » — un résultat
    # qu'on aurait pu arrondir à « les Bases sont couchées ». Les 180 Bases
    # non brillantes disent autre chose : 175 couchées, 5 debout, et **les cinq
    # sont des variantes `Hyperspace`**. L'orientation est donc une propriété
    # du couple (type, traitement), pas du type seul.
    #
    # Les entrées brillantes sont écartées du tirage : le CDN rend 403 sur leur
    # rendu, l'image étant celle de leur jumelle ordinaire.
    print(f"\n--- orientation, {sample} rendus par couple (type, traitement) ---")
    pools: dict[tuple[str, str], list[Print]] = defaultdict(list)
    for p in playable:
        if p.front_art and not p.is_foil:
            pools[(p.type, p.treatment)].append(p)

    #: Groupes où au moins un rendu couché est apparu, à vérifier exhaustivement.
    suspects: list[tuple[str, str]] = []
    for key in sorted(pools):
        pool = pools[key]
        # Un tirage réparti sur les extensions plutôt que les N premières
        # entrées : une maquette peut changer d'une extension à l'autre, et
        # regarder six cartes de la même en dirait moins que rien.
        picked = pool[:: max(1, len(pool) // sample)][:sample]
        ratios: list[float] = []
        for p in picked:
            try:
                with Image.open(probe.image(p.front_art)) as img:
                    ratios.append(img.width / img.height)
            except (ProbeError, OSError) as exc:
                print(f"      {key[0]}/{key[1]} {p.set_code}-{p.number} : {exc}")
        if not ratios:
            continue
        laid = sum(1 for r in ratios if r > 1)
        verdict = (
            "couchée" if laid == len(ratios)
            else "debout" if laid == 0
            else f"MÊLÉE ({laid}/{len(ratios)})"
        )
        print(f"  {key[0]:<10} {key[1] or 'Normal':<22} {len(pool):>5} impr."
              f"   {min(ratios):.3f}…{max(ratios):.3f}   {verdict}")
        if laid:
            suspects.append(key)

    # **Un échantillon ne peut pas dire qu'un groupe est homogène**, et c'est ce
    # que la première passe a failli faire conclure : cinq rendus tirés parmi
    # les 85 Bases `Hyperspace` sont tous tombés couchés, alors que cinq de ces
    # 85 sont imprimées debout. Une fenêtre mesurée sur un lot qu'on croit
    # homogène et qui ne l'est pas décrit une carte qui n'existe pas.
    #
    # La vérification exhaustive ne coûte que sur les groupes où au moins un
    # rendu couché est apparu : la masse du catalogue — Unit, Event, Upgrade —
    # est debout sans exception et n'est pas retéléchargée.
    print("\n--- vérification exhaustive des groupes où une carte couchée apparaît ---")
    for key in suspects:
        pool = pools[key]
        upright: list[Print] = []
        counts: Counter = Counter()
        for p in pool:
            try:
                with Image.open(probe.image(p.front_art)) as img:
                    if img.width > img.height:
                        counts["couchée"] += 1
                    else:
                        counts["debout"] += 1
                        upright.append(p)
            except (ProbeError, OSError):
                counts["illisible"] += 1
        print(f"  {key[0]}/{key[1] or 'Normal':<20} {len(pool):>5} impr. : "
              f"{dict(counts)}")
        for p in upright[:8]:
            label = f"{p.name} — {p.subtitle}" if p.subtitle else p.name
            print(f"      debout : {p.set_code}-{p.number:<6} {label[:48]}")


def report_prices(playable: list[Print]) -> None:
    """4. Le chaînage vers les prix : combien d'impressions sont joignables ?"""
    print("\n=== 4. chaînage vers TCGplayer ===")
    linked = [p for p in playable if p.tcgplayer_id]
    print(f"  avec `tcgplayerId` : {len(linked):>6} / {len(playable)} "
          f"({100 * len(linked) / len(playable):.1f} %)")
    missing = [p for p in playable if not p.tcgplayer_id]
    if missing:
        # Riftbound perd 227 impressions, toutes de sa dernière extension : un
        # trou concentré est un retard de la source, un trou réparti est un
        # défaut de couverture. Les deux ne se traitent pas pareil.
        print("  manquantes, par extension :")
        for code, n in Counter(p.set_code for p in missing).most_common(8):
            total = sum(1 for p in playable if p.set_code == code)
            print(f"      {code:<8} {n:>5} / {total}")
    # Un identifiant partagé n'est pas un défaut : c'est la signature du couple
    # ordinaire / brillante, TCGplayer ne voyant là qu'un seul produit coté dans
    # deux finitions. Le vérifier est ce qui permet d'affirmer que « Foil » est
    # une finition et non une impression — voir report_finishes.
    grouped = defaultdict(list)
    for p in linked:
        grouped[p.tcgplayer_id].append(p)
    shared = {tid: g for tid, g in grouped.items() if len(g) > 1}
    print(f"\n--- identifiants portés par plusieurs entrées : {len(shared)} ---")
    combos = Counter(tuple(sorted(x.variant for x in g)) for g in shared.values())
    for combo, n in combos.most_common(6):
        print(f"      {n:>5}  {' + '.join(combo)}")
    same_treatment = sum(
        1 for g in shared.values() if len({x.treatment for x in g}) == 1
    )
    print(f"  dont un seul traitement, deux finitions : {same_treatment} / {len(shared)}")


def report_finishes(playable: list[Print]) -> None:
    """5. Les finitions : où ce jeu déclare-t-il la brillante ?

    Le § 6 de l'annexe multi-jeu a coûté quatre corrections distinctes, et sa
    leçon est qu'**une finition se lit là où le jeu la déclare, jamais d'un
    principe** : `subTypeName` chez Riftbound et Pokémon, `imageUR` chez
    Wankul, et rien chez Yu-Gi-Oh, dont le champ homologue porte une édition.
    """
    print("\n=== 5. finitions : `VariantType` porte deux choses ===")
    treatments = Counter(p.treatment for p in playable)
    print(f"  valeurs brutes de `VariantType` : {len({p.variant for p in playable})}")
    print(f"  traitements, finition retirée   : {len(treatments)}")
    for value, n in treatments.most_common(12):
        foils = sum(1 for p in playable if p.treatment == value and p.is_foil)
        print(f"      {value or '(vide)':<22} {n - foils:>5} ordinaires, {foils:>5} brillantes")

    # La vérification qui décide : une entrée brillante est-elle toujours le
    # jumeau d'une entrée ordinaire ? Si oui, « Foil » est une finition et le
    # modèle actuel l'absorbe sans nouvelle colonne. Sinon, il existe des
    # impressions qui n'existent qu'en brillante — le cas Riftbound, où 704
    # impressions sont dans cette situation et comptent pour zéro euro dès
    # qu'un exemplaire ordinaire est saisi.
    print("\n--- une entrée brillante a-t-elle toujours son ordinaire ? ---")
    plain_keys = {(p.set_code, p.treatment, p.card_key) for p in playable if not p.is_foil}
    orphans = [
        p for p in playable
        if p.is_foil and (p.set_code, p.treatment, p.card_key) not in plain_keys
    ]
    foils = [p for p in playable if p.is_foil]
    print(f"  entrées brillantes            : {len(foils):>5}")
    print(f"  sans jumeau ordinaire         : {len(orphans):>5}")
    for p in orphans[:6]:
        print(f"      {p.set_code}-{p.number:<6} {p.name[:30]:<32} {p.variant}")

    # Ce que l'utilisateur pourra saisir : une carte dont aucune impression n'est
    # brillante ne doit pas proposer la case, et une carte qui l'est doit la
    # proposer. Le décompte se fait par carte, pas par impression.
    by_title = defaultdict(list)
    for p in playable:
        by_title[p.card_key].append(p)
    both = sum(1 for g in by_title.values() if any(p.is_foil for p in g) and any(not p.is_foil for p in g))
    only_foil = sum(1 for g in by_title.values() if all(p.is_foil for p in g))
    only_plain = sum(1 for g in by_title.values() if all(not p.is_foil for p in g))
    print(f"\n--- par carte ---")
    print(f"  existe dans les deux finitions : {both:>5}")
    print(f"  brillante seulement            : {only_foil:>5}")
    print(f"  ordinaire seulement            : {only_plain:>5}")


def run(sample: int) -> None:
    probe = Probe()
    sets, prints = load_catalogue(probe)
    playable = report_scope(prints, sets)
    report_identity(playable)
    report_layouts(playable, probe, sample)
    report_prices(playable)
    report_finishes(playable)
    print(f"\n{probe.requests} requêtes émises (le reste venait du cache)")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--sample",
        type=int,
        default=6,
        help="rendus regardés par type pour mesurer l'orientation (défaut 6)",
    )
    args = parser.parse_args()
    run(args.sample)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit("interrompu")
