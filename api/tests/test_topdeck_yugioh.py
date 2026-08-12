"""Tests de l'import des decklists Yu-Gi-Oh depuis TopDeck.gg.

**Ce qu'ils protègent, ce sont trois défauts qui ne lèvent rien.** Une zone de
deck saisie `#main` au lieu de `Deck` produit un pan principal vide : le deck est
compté « écarté, trop de cartes inconnues » et le corpus paraît simplement plus
petit — 305 decks sur 3 946 étaient dans ce cas. Un Extra Deck oublié produit
l'inverse et c'est pire : une liste annoncée constructible alors que quinze
cartes manquent. Et une table de traduction des passcodes qui rendrait vide là
où elle pouvait rendre une carte laisserait 93 decks enregistrés amputés, donc
annoncés plus complets qu'ils ne sont.

Aucun réseau : les réponses de la source sont figées en fixtures, réduites aux
champs dont les modules se servent.
"""

from __future__ import annotations

import uuid

from app.ingestion.card_resolver import PasscodeResolver
from app.ingestion.topdeck_client import normalise_yugioh_zone, yugioh_boards
from app.ingestion.topdeck_ingest import build_passcode_aliases
from app.ingestion.ygoprodeck_ingest import oracle_uuid

# --- fixtures ---------------------------------------------------------------

# Un deck tel que la source le sert : les zones canoniques, chaque entrée
# etiquetée par son nom mais identifiée par son passcode.
DECK_CANONIQUE = {
    "Deck": {
        "Dark Armed Dragon": {"id": "63719952", "count": 1},
        "Armageddon Knight": {"id": "28985331", "count": 2},
    },
    "Extra": {"Stardust Dragon": {"id": "44508094", "count": 1}},
    "Side": {"D.D. Crow": {"id": "72520073", "count": 3}},
    "metadata": {"name": "Blackwing", "colors": "n/a"},
}

# Le même deck saisi par un organisateur qui a ses habitudes. Mesuré : 265 decks
# ecrivent exactement ainsi.
DECK_LIBRE = {
    "#main": {
        "Dark Armed Dragon": {"id": "63719952", "count": 1},
        "Armageddon Knight": {"id": "28985331", "count": 2},
    },
    "#extra": {"Stardust Dragon": {"id": "44508094", "count": 1}},
    "!side": {"D.D. Crow": {"id": "72520073", "count": 3}},
    "metadata": {"name": "Blackwing"},
}


def identite(passcode: int) -> uuid.UUID:
    """Tient lieu de l'identité que le catalogue dérive du passcode."""
    return uuid.uuid5(uuid.NAMESPACE_URL, f"card:{passcode}")


# --- normalisation des zones ------------------------------------------------


def test_reconnait_les_zones_canoniques():
    assert normalise_yugioh_zone("Deck") == "main"
    assert normalise_yugioh_zone("Extra") == "extra"
    assert normalise_yugioh_zone("Side") == "side"


def test_reconnait_la_ponctuation_decorative():
    """265 decks écrivent ainsi ; les lire strictement les perdrait tous."""
    assert normalise_yugioh_zone("#main") == "main"
    assert normalise_yugioh_zone("#extra") == "extra"
    assert normalise_yugioh_zone("!side") == "side"


def test_reconnait_la_casse_et_les_decomptes_colles():
    assert normalise_yugioh_zone("Main Deck") == "main"
    assert normalise_yugioh_zone("main deck -41") == "main"
    assert normalise_yugioh_zone("Deck - 41 Cards") == "main"
    assert normalise_yugioh_zone("extra deck:15") == "extra"
    assert normalise_yugioh_zone("Extra~~ - 15 Cards") == "extra"


def test_extra_et_side_ne_versent_pas_dans_le_principal():
    """« extra deck » et « side deck » contiennent tous deux « deck ».

    C'est le piège que l'ordre des tests désamorce : les chercher après « deck »
    verserait l'Extra et la réserve dans le pan principal, ce qui gonflerait
    chaque deck de trente cartes.
    """
    assert normalise_yugioh_zone("Extra Deck") == "extra"
    assert normalise_yugioh_zone("Side Deck") == "side"
    assert normalise_yugioh_zone("side deck") == "side"


def test_ignore_la_zone_technique_et_l_inconnu():
    assert normalise_yugioh_zone("metadata") is None
    assert normalise_yugioh_zone("") is None
    assert normalise_yugioh_zone("???") is None
    assert normalise_yugioh_zone("Notes") is None


# --- aplatissement d'un deck ------------------------------------------------


def test_l_extra_compte_dans_le_pan_principal():
    """On ne joue pas sans lui : l'omettre annoncerait complet un deck amputé."""
    main, side = yugioh_boards(DECK_CANONIQUE)
    assert main == {"63719952": 1, "28985331": 2, "44508094": 1}


def test_la_reserve_reste_dehors():
    main, side = yugioh_boards(DECK_CANONIQUE)
    assert "72520073" not in main
    assert side == {"72520073": 3}


def test_les_zones_libres_donnent_le_meme_deck():
    assert yugioh_boards(DECK_LIBRE) == yugioh_boards(DECK_CANONIQUE)


def test_la_cle_retenue_est_le_passcode_pas_le_nom():
    main, _ = yugioh_boards(DECK_CANONIQUE)
    assert "Dark Armed Dragon" not in main
    assert "63719952" in main


def test_une_entree_sans_passcode_est_ignoree():
    """Mélanger passcodes et noms dans un même pan rendrait la moitié des
    cartes irrésolubles sans que rien ne dise laquelle."""
    main, _ = yugioh_boards({"Deck": {"Carte sans identite": {"count": 3}}})
    assert main == {}


def test_les_zones_repetees_se_cumulent():
    """Certaines listes ouvrent deux zones qui désignent le même pan."""
    main, _ = yugioh_boards(
        {
            "Deck": {"Upstart Goblin": {"id": "70368879", "count": 1}},
            "Main": {"Upstart Goblin": {"id": "70368879", "count": 2}},
        }
    )
    assert main == {"70368879": 3}


# --- résolution par passcode ------------------------------------------------


def build_resolver(aliases: dict[str, str] | None = None) -> PasscodeResolver:
    known = {str(identite(p)) for p in (63719952, 28985331, 44508094)}
    return PasscodeResolver(known, identite, aliases)


def test_resout_un_passcode_present_au_catalogue():
    assert build_resolver().resolve("63719952") == str(identite(63719952))


def test_refuse_un_passcode_absent_du_catalogue():
    """Insérer un identifiant absent violerait la clé étrangère et ferait
    échouer l'import entier — l'échec doit rester local et compté."""
    resolver = build_resolver()
    assert resolver.resolve("11111111") is None
    assert resolver.unresolved == {"11111111": 1}


def test_refuse_un_passcode_qui_n_est_pas_un_nombre():
    resolver = build_resolver()
    assert resolver.resolve("Dark Magician") is None
    assert resolver.unresolved == {"Dark Magician": 1}


def test_l_alias_rattrape_une_illustration_alternative():
    """Monster Reborn est `83764719` au catalogue et `83764718` en illustration
    alternative. Sans cette traduction, 97 decks sur 3 950 perdaient une carte,
    et 93 étaient enregistrés amputés — donc annoncés plus complets qu'ils ne
    sont."""
    attendu = str(identite(63719952))
    resolver = build_resolver(aliases={"63719953": attendu})
    assert resolver.resolve("63719953") == attendu
    assert resolver.unresolved == {}


def test_l_alias_ne_court_circuite_pas_le_catalogue():
    """Le repli ne vaut que pour les passcodes en échec : une carte présente au
    catalogue se résout par le calcul, quoi que dise la table de traduction."""
    resolver = build_resolver(aliases={"63719952": "identite-fausse"})
    assert resolver.resolve("63719952") == str(identite(63719952))


def test_resout_un_deck_entier_et_compte_les_pertes():
    resolver = build_resolver()
    main, _ = yugioh_boards(DECK_CANONIQUE)
    resolved, missing = resolver.resolve_deck(main)
    assert missing == 0
    assert resolved == {
        str(identite(63719952)): 1,
        str(identite(28985331)): 2,
        str(identite(44508094)): 1,
    }


# --- construction de la table de traduction --------------------------------
#
# C'est le chemin le plus exposé au deck enregistré amputé : s'il rend une table
# vide là où une carte était traduisible, rien ne lève et 93 decks perdent une
# carte en silence.


class DeckFactice:
    """Ce que `fetch_decks` rend, réduit à ce que la construction lit."""

    def __init__(self, mainboard: dict[str, int], sideboard: dict[str, int]):
        self.mainboard = mainboard
        self.sideboard = sideboard


def catalogue() -> tuple[set[str], dict[str, str]]:
    """Un catalogue où Monster Reborn n'existe que sous son passcode principal.

    **L'identité est ici celle du vrai catalogue** (`oracle_uuid`), et non le
    double injecté plus haut : cette fonction-là dérive l'identité elle-même,
    parce qu'elle appartient au connecteur d'un jeu précis. Un double la ferait
    passer pour vraie tout en mesurant autre chose.
    """
    known = {str(oracle_uuid(83764719))}
    names = {"monster reborn": str(oracle_uuid(83764719))}
    return known, names


def test_ne_demande_rien_quand_tout_se_resout():
    """Aucun appel réseau si le calcul suffit — le repli n'est pas une routine."""
    known, names = catalogue()
    appels = []

    def fetch(codes):
        appels.append(codes)
        return {}

    aliases = build_passcode_aliases(
        [DeckFactice({"83764719": 1}, {})], known, names, fetch
    )
    assert aliases == {}
    assert appels == []


def test_traduit_le_passcode_d_illustration_alternative():
    known, names = catalogue()
    aliases = build_passcode_aliases(
        [DeckFactice({"83764718": 1}, {})],
        known,
        names,
        lambda codes: {"83764718": "Monster Reborn"},
    )
    assert aliases == {"83764718": str(oracle_uuid(83764719))}


def test_releve_aussi_les_passcodes_de_la_reserve():
    """La réserve ne compte pas dans la complétion, mais ses cartes sont
    enregistrées : les omettre ici les rendrait introuvables sans raison."""
    known, names = catalogue()
    demandes = []

    def fetch(codes):
        demandes.extend(codes)
        return {}

    build_passcode_aliases([DeckFactice({}, {"83764718": 1})], known, names, fetch)
    assert demandes == ["83764718"]


def test_ignore_un_nom_absent_du_catalogue():
    """La source connaît des cartes que le catalogue écarte — celles qui n'ont
    jamais paru sur carton. Les traduire vers rien vaut mieux que vers l'à-peu-près."""
    known, names = catalogue()
    aliases = build_passcode_aliases(
        [DeckFactice({"11111111": 1}, {})],
        known,
        names,
        lambda codes: {"11111111": "Carte du dessin animé"},
    )
    assert aliases == {}


def test_une_source_muette_ne_casse_rien():
    """Panne réseau, réponse illisible, ou aucun passcode reconnu : le repli
    rend une table vide et l'import continue, sans traduction."""
    known, names = catalogue()
    aliases = build_passcode_aliases(
        [DeckFactice({"83764718": 1}, {})], known, names, lambda codes: {}
    )
    assert aliases == {}


def test_ne_demande_pas_ce_qui_n_est_pas_un_passcode():
    """Une entrée sans identifiant numérique n'est pas une carte à traduire."""
    known, names = catalogue()
    demandes = []

    def fetch(codes):
        demandes.extend(codes)
        return {}

    build_passcode_aliases(
        [DeckFactice({"Dark Magician": 1, "": 1}, {})], known, names, fetch
    )
    assert demandes == []


def test_un_passcode_cite_par_plusieurs_decks_n_est_demande_qu_une_fois():
    known, names = catalogue()
    demandes = []

    def fetch(codes):
        demandes.extend(codes)
        return {}

    build_passcode_aliases(
        [DeckFactice({"83764718": 1}, {}), DeckFactice({"83764718": 3}, {})],
        known,
        names,
        fetch,
    )
    assert demandes == ["83764718"]
