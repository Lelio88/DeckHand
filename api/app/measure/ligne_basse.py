"""Ce que ML Kit lit vraiment sur la ligne basse d'une carte (issue n°50, faisabilité).

Lit la sortie de `app/integration_test/ligne_basse_test.dart` — la bande basse
de chaque carte détourée, en pleine résolution, dans les quatre sens et à deux
échelles — et la confronte à la vérité du banc (`carte-seule/attendu.csv`,
extension et numéro lus à l'œil sur le carton).

**Deux mentions, jugées séparément** :

* le **numéro de collection**, reconnu seulement sous une forme qui dit qu'on
  lit un numéro — « 247/350 » ou « 0348 » à zéros de tête. Un nombre nu (« 5 »,
  « 2025 ») ne compte pas : il pourrait être n'importe quoi. Juste s'il vaut le
  numéro réel, **faux** s'il en vaut un autre — le cas qui produirait une
  édition fausse ;
* l'**année du copyright**, juste à un an près de la sortie de l'extension (la
  tolérance du banc de catalogue `edition_from_print_line`).

**Les quatre sens sont réunis.** Le test ne sait pas de quel côté est le bas
du carton ; l'application, elle, le sait par l'illustration. Une lecture juste
dans n'importe quel sens compte donc, ce qui rend la mesure un peu optimiste
pour le numéro « faux » : un chiffre lu sur un bord latéral n'aurait pas été
lu par l'application.

Usage :
    cd api && .venv/Scripts/python -m app.measure.ligne_basse <ligne_basse.log>
"""

from __future__ import annotations

import csv
import re
import sys
from collections import defaultdict
from pathlib import Path

import psycopg

from app.config import SupabaseConfig

TRUTH = Path(__file__).resolve().parents[4] / ".deckhand-bench/photos/carte-seule/attendu.csv"

_LINE = re.compile(r"^BANDE (\S+) tour=(\d) ([xr])(\d) « (.*) »\s*$")
_MISSING = re.compile(r"^BANDE (\S+) ([xr]) sans-carte")
_WITH_TOTAL = re.compile(r"(?<!\d)(\d{1,4})\s*/\s*(\d{1,4})(?!\d)")
_ZERO_PADDED = re.compile(r"(?<!\d)0(\d{2,3})(?!\d)")
_YEAR = re.compile(r"(?<!\d)(19[89]\d|20[0-3]\d)(?!\d)")
#: Un O collé à un chiffre : ML Kit rend « C 0195 » en « CO195 ».
_O_AS_ZERO = re.compile(r"(?<=\d)[Oo]|[Oo](?=\d)")
#: Sous ce total, un « n/total » est la force et l'endurance (« 4/4 »), imprimées
#: dans la même bande : aucune extension de Magic n'a moins de vingt cartes
#: numérotées sur ce modèle, aucune créature imprimée n'a vingt d'endurance.
MIN_TOTAL = 20


def read_numbers(text: str) -> set[int]:
    """Les numéros de collection lisibles comme tels dans une ligne."""
    text = _O_AS_ZERO.sub("0", text)
    found = {
        int(m.group(1))
        for m in _WITH_TOTAL.finditer(text)
        if int(m.group(2)) >= MIN_TOTAL and int(m.group(1)) <= int(m.group(2))
    }
    found |= {int(m.group(1)) for m in _ZERO_PADDED.finditer(text)}
    return found


def read_years(text: str) -> set[int]:
    return {int(m.group(1)) for m in _YEAR.finditer(text)}


def verdict(read: set[int], truth: int) -> str:
    """Juste seulement si le bon numéro est **seul** lu : devant deux numéros,
    l'application renoncerait, comme `readSetCode` devant deux codes."""
    if read == {truth}:
        return "juste"
    if truth in read:
        return "ambigu"
    return "faux" if read else "rien"


#: Ce qui ne s'imprime qu'au bas du carton : copyright, illustrateur, éditeur.
_BOTTOM_MARK = re.compile(r"wizard|illus|©|marvel|inc\.", re.IGNORECASE)


def bottom_turn(by_turn: dict[int, list[str]]) -> int | None:
    """Le quart de tour où la bande lue est bien le bas du carton.

    L'application connaît le sens de la carte par son illustration ; le banc,
    lui, l'infère de ce qui ne s'imprime qu'en bas. Aucun repère : `None`, et
    la photo compte comme rien lu — on ne devine pas le sens.
    """
    marks = {turn: sum(bool(_BOTTOM_MARK.search(t)) for t in texts) for turn, texts in by_turn.items()}
    best = max(marks.values(), default=0)
    if best == 0:
        return None
    winners = [turn for turn, n in marks.items() if n == best]
    return winners[0] if len(winners) == 1 else None


def parse_log(
    lines,
) -> tuple[dict[tuple[str, int, str, int], list[str]], set[tuple[str, str]]]:
    """Lignes lues par (photo, tour, source, échelle), et (photo, source) sans
    carte détourée. Source « x » : pleine résolution ; « r » : réduite à 1600."""
    read: dict[tuple[str, int, str, int], list[str]] = defaultdict(list)
    missing: set[tuple[str, str]] = set()
    for raw in lines:
        raw = raw.strip()
        if m := _LINE.match(raw):
            key = (m.group(1), int(m.group(2)), m.group(3), int(m.group(4)))
            read[key].append(m.group(5))
        elif m := _MISSING.match(raw):
            missing.add((m.group(1), m.group(2)))
    return dict(read), missing


def load_truth() -> dict[str, tuple[str, int]]:
    truth: dict[str, tuple[str, int]] = {}
    with TRUTH.open(encoding="utf-8") as f:
        for row in csv.reader(f, delimiter=";"):
            if not row or row[0].startswith("#") or len(row) < 3 or row[1] == "-":
                continue
            truth[row[0]] = (row[1], int(re.sub(r"\D", "", row[2])))
    return truth


#: Les numéros des huit cartes Marvel (MSH) des photos d'`etalement/`, identifiées
#: à l'œil sur les photos et numérotées par `carte-seule/attendu.csv`, qui porte
#: les mêmes cartes photographiées seules : Doombot aérien, Dinosaure de la
#: Terre sauvage, Oiseau Moqueur, Haut responsable chez Stark Industries, Agent
#: d'Atlas, Shuri, Crescendo brûlant, Sortilège magique.
SPREAD_NUMBERS = {43, 185, 22, 153, 3, 75, 125, 133}


def spread_verdict(read: set[int], truth: set[int]) -> str:
    """Verdict d'une carte d'étalement, faute de savoir laquelle est laquelle.

    Faux dès qu'un nombre lu n'est celui d'aucune carte de la photo ; juste
    pour un seul numéro, de la photo. Le numéro d'une **voisine** passerait pour
    juste : la mesure dit le taux de lecture et l'absence d'invention, pas
    l'attribution — que l'étalement fait par ailleurs, par le nom.
    """
    if not read:
        return "rien"
    if read - truth:
        return "faux"
    return "juste" if len(read) == 1 else "ambigu"


def main_spread(read, missing) -> int:
    for source, name in (("x", "pleine résolution"), ("r", "réduite à 1600 px")):
        cards = sorted({p for (p, _, s, _) in read if s == source and "#" in p})
        photos = sorted({c.split("#")[0] for c in cards})
        count: dict[str, int] = defaultdict(int)
        for card in cards:
            by_turn: dict[int, list[str]] = defaultdict(list)
            for (p, turn, s, _), texts in read.items():
                if p == card and s == source:
                    by_turn[turn].extend(texts)
            turn = bottom_turn(by_turn)
            texts = by_turn.get(turn, []) if turn is not None else []
            numbers = set().union(*(read_numbers(x) for x in texts)) if texts else set()
            count[spread_verdict(numbers, SPREAD_NUMBERS)] += 1
        lost = sum(1 for (_, s) in missing if s == source)
        print(
            f"{name:<18} {len(photos)} photos, {len(cards)} cartes détourées "
            f"({lost} photo(s) sans carte) : juste {count['juste']}  "
            f"ambigu {count['ambigu']}  faux {count['faux']}  rien {count['rien']}"
        )
    return 0


def main() -> int:
    log = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace").splitlines()
    if "--etalement" in sys.argv:
        read, missing = parse_log(log)
        return main_spread(read, missing)
    read, missing = parse_log(log)
    truth = load_truth()
    with psycopg.connect(SupabaseConfig.load().db_url, connect_timeout=30) as conn:
        years = dict(
            conn.execute(
                "SELECT set_code, MIN(EXTRACT(YEAR FROM released_at))::int "
                "FROM public.card_prints WHERE set_code = ANY(%s) GROUP BY set_code",
                (list({s for s, _ in truth.values()}),),
            ).fetchall()
        )

    photos = sorted(truth)

    def readings(photo: str, source: str, scales: tuple[int, ...]) -> tuple[set[int], set[int]]:
        by_turn: dict[int, list[str]] = defaultdict(list)
        for (p, turn, src, scale), texts in read.items():
            if p == photo and src == source and scale in scales:
                by_turn[turn].extend(texts)
        turn = bottom_turn(by_turn)
        texts = by_turn.get(turn, []) if turn is not None else []
        numbers = set().union(*(read_numbers(t) for t in texts)) if texts else set()
        found_years = set().union(*(read_years(t) for t in texts)) if texts else set()
        return numbers, found_years

    n = len(photos)
    print(f"Photos à vérité connue : {n}")
    for source, name in (("x", "pleine résolution"), ("r", "réduite à 1600 px")):
        lost = sum(1 for p in photos if (p, source) in missing)
        print(f"  {name:<18} carte non détourée : {lost}")
    print()
    print("Numéro lu dans le sens du copyright ; « juste » = seul numéro lu, et le bon.")
    for source, name in (("x", "pleine"), ("r", "1600 px")):
        for scales, label in (((1,), "×1"), ((2,), "×2"), ((1, 2), "×1 ou ×2")):
            count: dict[str, int] = defaultdict(int)
            year_ok = 0
            for photo in photos:
                numbers, found_years = readings(photo, source, scales)
                set_code, number = truth[photo]
                count[verdict(numbers, number)] += 1
                if any(abs(y - years.get(set_code, 0)) <= 1 for y in found_years):
                    year_ok += 1
            print(
                f"{name:<8}{label:<10} juste {count['juste']:>2}/{n}  "
                f"ambigu {count['ambigu']:>2}  faux {count['faux']:>2}  "
                f"rien {count['rien']:>2}   |   année juste (±1) {year_ok:>2}/{n}"
            )

    print()
    print("Détail par photo (×1 ou ×2), pleine | 1600 px :")
    for photo in photos:
        set_code, number = truth[photo]
        full, _ = readings(photo, "x", (1, 2))
        small, _ = readings(photo, "r", (1, 2))
        print(
            f"  {photo} {set_code}#{number:<4} "
            f"{verdict(full, number):<6} {sorted(full)!s:<12} | "
            f"{verdict(small, number):<6} {sorted(small)}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
