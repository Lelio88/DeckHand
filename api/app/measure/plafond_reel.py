"""Ce que l'application reconnaît vraiment — dépouillement du banc sur appareil.

**Pourquoi ce banc existe.** `plafond_empreinte` mesure la voie de l'empreinte,
la seule qu'un banc `dart run` puisse exécuter : ML Kit est un greffon natif. Or
le mode photo réel lit d'abord les **noms** et ne tombe sur l'illustration que si
rien n'a été lu. Les taux publiés jusqu'ici décrivaient donc le recours, jamais
l'application — et rien ne permettait de déduire l'un de l'autre.

`app/integration_test/plafond_reel_test.dart` appelle le vrai `recognisePhoto`
sur l'appareil et écrit une ligne par photo. Ce module la rapproche de la vérité
du banc (`attendu.csv`, comptée à l'œil) et rend le tableau.

**La correspondance se fait par `oracle_id`.** Le test rend des identifiants, la
vérité une extension et un numéro de collection ; Scryfall fait le pont. Comparer
des noms échouerait sur la langue — les cartes sont françaises, le catalogue
anglais.

Usage :
    .venv/Scripts/python -m app.measure.plafond_reel <journal.log>
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
from pathlib import Path

import httpx

sys.stdout.reconfigure(encoding="utf-8") if hasattr(sys.stdout, "reconfigure") else None

USER_AGENT = "DeckHand/1.0 (banc de mesure ; contact heianenterpriseyt@gmail.com)"
CACHE = Path(".cache/plafond")

#: Une ligne du journal, telle que le test embarqué l'écrit.
LIGNE = re.compile(
    r"PLAFOND-REEL (?P<fichier>\S+\.jpg) "
    r"noms_lus=(?P<noms>\d+) "
    r"voie=(?P<voie>\S+) "
    r"sur=(?P<sur>true|false) "
    r"methode=(?P<methode>\S+) "
    r"ms=(?P<ms>\d+) "
    r"cartes=\[(?P<cartes>.*)\]"
)


def lire_attendu(chemin: Path) -> dict[str, tuple[str, str, str]]:
    """La vérité du banc : quelle carte porte quelle photo."""
    attendu: dict[str, tuple[str, str, str]] = {}
    for ligne in chemin.read_text(encoding="utf-8").splitlines():
        nu = ligne.strip()
        if not nu or nu.startswith("#"):
            continue
        champs = [c.strip() for c in nu.split(";")]
        if len(champs) >= 3 and champs[1] != "-":
            attendu[champs[0]] = (champs[1], champs[2], champs[3] if len(champs) > 3 else "")
    return attendu


def oracle_de(client: httpx.Client, extension: str, numero: str) -> tuple[str, str]:
    """L'`oracle_id` et le nom d'une impression, par son extension et son numéro."""
    fiche = CACHE / f"{extension}-{numero}.json"
    if fiche.exists():
        carte = json.loads(fiche.read_text(encoding="utf-8"))
    else:
        reponse = client.get(
            f"https://api.scryfall.com/cards/{extension}/{numero}", timeout=30
        )
        reponse.raise_for_status()
        carte = reponse.json()
        time.sleep(0.15)
        fiche.parent.mkdir(parents=True, exist_ok=True)
        fiche.write_text(json.dumps(carte), encoding="utf-8")
    return carte["oracle_id"], carte.get("name", "?")


def main() -> None:
    parseur = argparse.ArgumentParser(description=__doc__)
    parseur.add_argument("journal")
    parseur.add_argument(
        "--attendu",
        default="../../.deckhand-bench/photos/carte-seule/attendu.csv",
    )
    arguments = parseur.parse_args()

    attendu = lire_attendu(Path(arguments.attendu))
    texte = Path(arguments.journal).read_text(encoding="utf-8", errors="replace")
    lignes = [m.groupdict() for m in LIGNE.finditer(texte)]
    if not lignes:
        print(
            "aucune ligne PLAFOND-REEL dans le journal — le test a-t-il tourné ?"
        )
        return

    justes = fausses = muettes = hors = 0
    par_voie: dict[str, int] = {}
    detail: list[str] = []

    with httpx.Client(headers={"User-Agent": USER_AGENT}) as client:
        for l in lignes:
            fichier = l["fichier"]
            cible = attendu.get(fichier)
            if cible is None:
                hors += 1
                continue
            oracle, nom_attendu = oracle_de(client, cible[0], cible[1])

            rendus = [
                c.split("|", 1)[0] for c in l["cartes"].split(" ; ") if c.strip()
            ]
            sur = l["sur"] == "true"
            voie = l["voie"]

            # **`sur` ne veut rien dire sur la voie du nom.** `PhotoOutcome` le
            # met à vrai par défaut, et la lecture en lot ne le renseigne pas :
            # l'afficher là ferait passer une valeur par défaut pour une mesure.
            assurance = ("sûre" if sur else "à départager") if voie == "illustration" else "—"

            if not rendus:
                etat = "MUETTE"
                muettes += 1
            elif oracle in rendus:
                # **Proposée ne vaut pas annoncée.** Le mode photo rend jusqu'à
                # trois candidats quand il doute ; le rang dit si la bonne était
                # en tête ou noyée dans une liste à départager.
                rang = rendus.index(oracle)
                etat = f"JUSTE (rang {rang + 1}/{len(rendus)}, {assurance})"
                justes += 1
            else:
                etat = f"FAUSSE ({len(rendus)} proposée(s), {assurance})"
                fausses += 1
            par_voie[voie] = par_voie.get(voie, 0) + 1

            detail.append(
                f"  {fichier[-13:-4]}  {nom_attendu[:26]:28s} "
                f"noms_lus={l['noms']:>2s}  voie={voie:12s} "
                f"{int(l['ms']):>5d} ms  {etat}"
            )

    print(f"{len(detail)} photos a carte unique\n")
    print("\n".join(detail))
    total = justes + fausses + muettes
    print(f"\n{'=' * 78}")
    print(f"  {justes} justes, {fausses} fausses, {muettes} muettes sur {total}")
    print("  par voie : " + ", ".join(f"{v} : {n}" for v, n in sorted(par_voie.items())))
    if hors:
        print(f"  ({hors} photo(s) sans carte unique, ecartees)")


if __name__ == "__main__":
    main()
