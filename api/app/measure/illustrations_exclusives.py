"""Combien d'illustrations n'existent que sur des impressions hors en/fr ?

**La question que ce banc tranche.** `scryfall_ingest.KEEP_LANGS` ne garde que
les impressions anglaises et françaises. Pour une œuvre qui existe aussi dans
ces langues, c'est sans conséquence : l'empreinte est calculée sur l'impression
anglaise et la carte est reconnue quelle que soit la langue du carton — l'art
est le même. Mais une œuvre **exclusive** à une impression japonaise n'entre
alors nulle part : ni `card_prints`, ni `illustration_id`, ni `art_hashes`.

Constaté sur trois cartes du propriétaire — les terrains *ukiyo-e* de Kamigawa
(`neo` 296, 301, 302), que Scryfall ne publie qu'en `ja`. Le scan échoue sans
recours possible : aucun gabarit d'illustration ne peut retrouver une œuvre
absente de l'index.

**Pourquoi l'API de recherche ne suffisait pas.** `-in:en` y porte sur la
**carte** et non sur l'impression : « Forêt » existe en anglais, donc la requête
écarte ses terrains japonais. Elle répondait 3 là où le vrai compte se lit par
`illustration_id`, ce que seul l'export complet permet.

**Et l'identifiant se lit comme l'ingestion le lit.** Une première version de ce
banc prenait `illustration_id` à la racine du payload et annonçait 309 : dix de
ces œuvres sont portées par une carte recto-verso, dont la racine est vide et
dont seule la face porte l'identifiant — une impression anglaise les couvre
donc, et elles ne sont pas orphelines. D'où `illustration_id_of`, partagé avec
`scryfall_parse` : un banc qui compte autrement que le code mesure autre chose.

Usage :
    cd api && .venv/Scripts/python -m app.measure.illustrations_exclusives
"""

from __future__ import annotations

import sys

from app.ingestion.scryfall_client import BULK_ALL, stream_bulk
from app.ingestion.scryfall_parse import illustration_id_of, should_ingest

sys.stdout.reconfigure(encoding="utf-8") if hasattr(sys.stdout, "reconfigure") else None

KEEP_LANGS = frozenset({"en", "fr"})


def main() -> int:
    #: Par illustration : les langues où elle paraît, et un exemple lisible.
    langues: dict[str, set[str]] = {}
    exemple: dict[str, tuple[str, str, str]] = {}
    vues = 0

    for payload in stream_bulk(BULK_ALL):
        vues += 1
        if vues % 50_000 == 0:
            print(f"  parcourues : {vues}", end="\r", flush=True)

        illus = illustration_id_of(payload)
        if not illus or not should_ingest(payload):
            continue
        lang = payload.get("lang") or "en"
        langues.setdefault(illus, set()).add(lang)
        exemple.setdefault(
            illus,
            (payload.get("set", "?"), payload.get("collector_number", "?"),
             payload.get("name", "?")),
        )

    print(f"  parcourues : {vues}      ")
    exclusives = {i: ls for i, ls in langues.items() if not (ls & KEEP_LANGS)}

    print()
    print(f"illustrations du périmètre      : {len(langues)}")
    print(f"dont sans impression en ni fr   : {len(exclusives)}"
          f"  ({100 * len(exclusives) / max(len(langues), 1):.2f} %)")

    par_langue: dict[str, int] = {}
    for ls in exclusives.values():
        for lang in ls:
            par_langue[lang] = par_langue.get(lang, 0) + 1
    print("\npar langue (une œuvre peut paraître dans plusieurs) :")
    for lang, n in sorted(par_langue.items(), key=lambda kv: -kv[1]):
        print(f"  {lang:<6}{n:>6}")

    par_set: dict[str, int] = {}
    for illus in exclusives:
        code = exemple[illus][0]
        par_set[code] = par_set.get(code, 0) + 1
    print("\nles extensions les plus touchées :")
    for code, n in sorted(par_set.items(), key=lambda kv: -kv[1])[:12]:
        print(f"  {code:<8}{n:>5}")

    print("\nquelques exemples :")
    for illus in list(exclusives)[:6]:
        code, num, nom = exemple[illus]
        print(f"  {code} #{num:<6}{nom[:34]:<36}{sorted(exclusives[illus])}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
