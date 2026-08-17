"""Ce que Lorcast publie, avant d'en écrire une ligne en base.

Cinq questions, dans l'ordre où une réponse négative arrête la suivante :

1. **le périmètre** — combien de cartes, d'extensions, de langues. Une source
   qui ne publierait que l'anglais ferait de Lorcana un jeu où l'illustration
   prime sur le nom, comme Riftbound et SWU ;
2. **l'identité** — quelle clé désigne une carte sans jamais en fusionner deux.
   Trois jeux ont payé cette question : Yu-Gi-Oh et Pokémon par une réingestion
   complète, Wankul en la prenant à temps ;
3. **les maquettes** — combien de fenêtres d'illustration la reconnaissance
   devra distinguer. SWU en a demandé cinq, Pokémon trois, One Piece une ;
4. **les prix** — la source les publie-t-elle, et pour quelles finitions. C'est
   le seul catalogue du projet qui prétend porter les deux ;
5. **les formats** — ce que `legalities` déclare, et ce qu'il faut en retenir.

Ce banc ne touche pas la base : il lit la sonde en cache et rend des nombres.

Usage :
    cd api && .venv/Scripts/python -m app.measure.lorcana_taxonomy
"""

from __future__ import annotations

import argparse
import collections
import statistics
import sys
from typing import Any

from app.measure.lorcast_probe import Probe


def perimetre(cards: list[dict[str, Any]], sets: list[dict[str, Any]]) -> None:
    print("=== 1. périmètre ===")
    print(f"  {len(cards)} cartes, {len(sets)} extensions")
    langues = collections.Counter(c.get("lang") for c in cards)
    print(f"  langues : {dict(langues)}")
    if set(langues) == {"en"}:
        print("  -> anglais seul : l'illustration prime sur le nom, comme Riftbound et SWU")
    sans_image = sum(1 for c in cards if not (c.get("image_uris") or {}).get("digital"))
    print(f"  sans illustration : {sans_image}")


def identite(cards: list[dict[str, Any]]) -> None:
    """Quelle clé désigne une carte sans jamais en fusionner deux.

    Quatre candidates sont éprouvées côte à côte. Le critère est brutal : une
    clé qui compte moins de valeurs distinctes que de cartes **fusionne**, et
    chaque fusion est une carte que la collection ne pourra jamais distinguer.
    """
    print()
    print("=== 2. identité ===")
    candidates: dict[str, collections.Counter] = {
        "id de la source": collections.Counter(c.get("id") for c in cards),
        "nom seul": collections.Counter(c.get("name") for c in cards),
        "nom + version": collections.Counter(
            (c.get("name"), c.get("version")) for c in cards
        ),
        "extension + numéro": collections.Counter(
            ((c.get("set") or {}).get("code"), c.get("collector_number")) for c in cards
        ),
    }
    for nom, compte in candidates.items():
        fusions = sum(n - 1 for n in compte.values() if n > 1)
        verdict = "OK" if fusions == 0 else f"FUSIONNE {fusions} cartes"
        print(f"  {nom:22} {len(compte):5} valeurs distinctes   {verdict}")
        if fusions:
            pires = [k for k, v in compte.most_common(3) if v > 1]
            print(f"      pires : {pires}")


def maquettes(cards: list[dict[str, Any]]) -> None:
    """Combien de fenêtres d'illustration la reconnaissance devra distinguer.

    Deux axes sont candidats — `layout`, que la source publie, et `type`. La
    question à trancher est de savoir s'ils disent la même chose : si `landscape`
    et `Location` recouvrent exactement le même ensemble, un seul suffit, et
    c'est `layout` qui gagne — il parle d'impression, pas de règle du jeu.
    """
    print()
    print("=== 3. maquettes ===")
    layouts = collections.Counter(c.get("layout") for c in cards)
    types = collections.Counter(t for c in cards for t in (c.get("type") or []))
    print(f"  layouts : {dict(layouts)}")
    print(f"  types   : {dict(types)}")

    couches = {c["id"] for c in cards if c.get("layout") == "landscape"}
    lieux = {c["id"] for c in cards if "Location" in (c.get("type") or [])}
    print(f"  couchées {len(couches)}, Lieux {len(lieux)}")
    if couches == lieux:
        print("  -> les deux axes recouvrent le MÊME ensemble : `layout` suffit,")
        print("    et il est le bon — il parle d'impression, non de règle du jeu")
    else:
        print(f"  -> ils divergent de {len(couches ^ lieux)} cartes : mesurer les deux")


def prix(cards: list[dict[str, Any]]) -> None:
    """La source publie-t-elle les prix, et pour quelles finitions.

    **C'est le seul catalogue du projet qui prétend porter les deux.** Partout
    ailleurs il a fallu un second connecteur — TCGCSV pour quatre jeux, et rien
    du tout pour Wankul, qu'aucun index public ne cote.
    """
    print()
    print("=== 4. prix ===")
    total = len(cards)
    ordinaire = sum(1 for c in cards if (c.get("prices") or {}).get("usd"))
    brillante = sum(1 for c in cards if (c.get("prices") or {}).get("usd_foil"))
    ni = sum(1 for c in cards if not (c.get("prices") or {}))
    print(f"  ordinaire : {ordinaire}/{total} ({100 * ordinaire / total:.1f} %)")
    print(f"  brillante : {brillante}/{total} ({100 * brillante / total:.1f} %)")
    print(f"  ni l'un ni l'autre : {ni}")

    cles = collections.Counter(k for c in cards for k in (c.get("prices") or {}))
    print(f"  clés publiées : {dict(cles)}")
    print("  devise : dollar — à convertir au taux BCE, comme les quatre autres jeux cotés")

    sans_tcg = sum(1 for c in cards if not c.get("tcgplayer_id"))
    print(f"  sans tcgplayer_id : {sans_tcg} (secours inutile tant que `prices` tient)")

    valeurs = [
        float(c["prices"]["usd"]) for c in cards if (c.get("prices") or {}).get("usd")
    ]
    if valeurs:
        valeurs.sort()
        print(
            f"  ordinaire : médiane {statistics.median(valeurs):.2f} $, "
            f"max {valeurs[-1]:.2f} $"
        )


def formats(cards: list[dict[str, Any]]) -> None:
    print()
    print("=== 5. formats ===")
    legalites = collections.Counter(
        f"{k}={v}" for c in cards for k, v in (c.get("legalities") or {}).items()
    )
    print(f"  {dict(legalites)}")
    print("  -> un seul format construit, `core`. Les non-légales sont les promos")
    print("    et les formats maison, que le constructeur n'a pas à proposer.")

    hors = [c for c in cards if (c.get("legalities") or {}).get("core") != "legal"]
    par_extension = collections.Counter(
        (c.get("set") or {}).get("code") for c in hors
    )
    print(f"  hors format, par extension : {dict(par_extension.most_common(8))}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--refresh", action="store_true", help="ignore le cache")
    args = parser.parse_args(argv)

    with Probe(quiet=True, refresh=args.refresh) as probe:
        sets = probe.sets()
        cards = probe.all_cards()

    perimetre(cards, sets)
    identite(cards)
    maquettes(cards)
    prix(cards)
    formats(cards)
    return 0


if __name__ == "__main__":
    sys.exit(main())
