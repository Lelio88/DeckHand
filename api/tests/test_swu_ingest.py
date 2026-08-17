"""Tests du connecteur de catalogue Star Wars Unlimited.

Chaque cas correspond à un piège réellement mesuré sur la source, ou à une
propriété dont dépend directement une ligne écrite en base. Aucun réseau : les
entrées sont construites à la main, dans la forme exacte que la source publie.
"""

from __future__ import annotations

from typing import Any

from app.ingestion.swu_ingest import (
    Entry,
    _as_number,
    canonicalise,
    fold_cards,
    fold_printings,
    parse_entry,
)


def entry(**kwargs: Any) -> Entry:
    defaults: dict[str, Any] = dict(
        set_code="SOR",
        number="001",
        name="Boba Fett",
        subtitle="Collecting the Bounty",
        type="Leader",
        variant="Normal",
        rarity="Common",
        aspects=("Cunning", "Villainy"),
        traits=("UNDERWORLD",),
        arenas=("Ground",),
        cost="5",
        text="When an enemy unit leaves play…",
        front_art="https://cdn.swu-db.com/images/cards/SOR/001.png",
        tcgplayer_id="540122",
    )
    defaults.update(kwargs)
    return Entry(**defaults)


# --- une finition n'est pas une impression ----------------------------------


def test_une_entree_brillante_ne_cree_pas_une_impression_de_plus():
    """**Le piège principal de cette source.** Les compter séparément
    gonflerait `card_prints` de moitié et ferait apparaître deux lignes de
    collection pour un seul exemplaire — le défaut que Riftbound a payé sur ses
    243 variantes suffixées. La preuve que c'est bien une seule impression est
    dans les identifiants TCGplayer : 878 des 880 partagés ne recouvrent qu'un
    traitement."""
    ordinaire = entry(number="001", variant="Normal")
    brillante = entry(number="501", variant="Foil")
    assert ordinaire.print_key == brillante.print_key

    printings = fold_printings([ordinaire, brillante])
    assert len(printings) == 1
    assert printings[0].finishes == ["nonfoil", "foil"]


def test_l_entree_ordinaire_fournit_le_numero_et_l_illustration():
    """C'est son numéro qui est imprimé sur la carte que l'on range en
    classeur, et son rendu que le CDN sert réellement — celui de la brillante
    répond 403."""
    ordinaire = entry(number="001", front_art="https://x/SOR/001.png")
    brillante = entry(number="501", variant="Foil", front_art="https://x/SOR/501.png")

    for ordre in ([ordinaire, brillante], [brillante, ordinaire]):
        printing = fold_printings(ordre)[0]
        assert printing.number == "001"
        assert printing.front_art == "https://x/SOR/001.png"


def test_foil_seul_est_la_brillante_de_normal():
    """La source rompt ici sa propre règle de suffixe : la brillante de
    `Normal` ne s'appelle pas « Normal Foil ». Lire un suffixe et rien d'autre
    classerait 1 148 impressions parmi les ordinaires."""
    assert entry(variant="Foil").is_foil
    assert entry(variant="Foil").treatment == "Normal"
    assert entry(variant="Hyperspace Foil").treatment == "Hyperspace"
    assert not entry(variant="Prestige Serialized").is_foil


def test_un_traitement_different_est_une_impression_differente():
    """`Hyperspace` n'est pas une finition mais un tirage distinct, qui a son
    propre prix et que l'utilisateur possède ou non."""
    assert entry(variant="Normal").print_key != entry(variant="Hyperspace").print_key


def test_une_impression_qui_n_existe_qu_en_brillante_le_declare():
    """Les quatre Bases Gamegenic sont dans ce cas. Leur donner `nonfoil` par
    défaut ferait proposer une case que le carton n'a jamais eue."""
    printing = fold_printings([entry(variant="Hyperspace Foil")])[0]
    assert printing.finishes == ["foil"]
    assert printing.number == "001"


# --- l'identité d'une carte -------------------------------------------------


def test_un_titre_porte_par_deux_types_fait_deux_cartes():
    """« Snapshot Reflexes » est un Event et un Upgrade — le seul cas sur
    2 180 titres. Les fusionner ferait perdre celle qui est possédée."""
    event = entry(name="Snapshot Reflexes", subtitle="", type="Event")
    upgrade = entry(name="Snapshot Reflexes", subtitle="", type="Upgrade")
    assert event.oracle_id != upgrade.oracle_id
    assert len(fold_cards([event, upgrade])) == 2


def test_une_reimpression_dans_une_autre_extension_reste_la_meme_carte():
    """320 titres du catalogue sont dans ce cas, par les promos OP. En faire
    deux cartes dédoublerait la collection et le catalogue."""
    original = entry(set_code="LOF", number="012")
    promo = entry(set_code="P25", number="004", variant="OP Promo")
    assert original.oracle_id == promo.oracle_id
    assert len(fold_cards([original, promo])) == 1
    # Deux impressions, en revanche : ce sont deux cartons distincts.
    assert len(fold_printings([original, promo])) == 2


def test_le_titre_reunit_le_nom_et_le_sous_titre():
    assert entry().title == "Boba Fett | Collecting the Bounty"
    assert entry(name="Data Vault", subtitle="").title == "Data Vault"


# --- le périmètre -----------------------------------------------------------


def test_un_jeton_se_reconnait_a_son_type():
    """Le nom d'extension se trompe : `GG` (Gamegenic) contient des jetons sans
    le dire. Le type est un vocabulaire, le nom d'extension un libellé."""
    assert entry(type="Token Upgrade", set_code="GG").is_token
    assert not entry(type="Upgrade").is_token


# --- ce que le schéma impose ------------------------------------------------


def test_un_cout_absent_devient_zero_car_la_colonne_le_refuse():
    """`cards.cmc` est `NOT NULL DEFAULT 0`. Le zéro est donc imposé, pas
    choisi : une Base n'a pas de coût, et son zéro se lira « gratuite »."""
    assert _as_number("5") == 5.0
    assert _as_number("") == 0.0
    assert _as_number(None) == 0.0


# --- la lecture de la source ------------------------------------------------


def test_une_entree_sans_variante_est_traitee_comme_ordinaire():
    """Toutes les entrées n'en portent pas ; en l'absence, la carte est le
    tirage de base et non un traitement anonyme."""
    parsed = parse_entry({"Name": "X", "Type": "Unit"}, fallback_set="sor")
    assert parsed.treatment == "Normal"
    assert not parsed.is_foil
    assert parsed.set_code == "SOR"


def test_le_code_d_extension_de_la_carte_prime_sur_celui_demande():
    """Une extension peut servir des cartes qui déclarent une autre extension —
    les promos en sont pleines. C'est ce que la carte dit qui compte."""
    parsed = parse_entry({"Set": "P25", "Name": "X", "Type": "Unit"}, fallback_set="lof")
    assert parsed.set_code == "P25"


# --- l'identité, quand la source s'écrit de deux façons ---------------------


def test_deux_ecritures_d_un_meme_titre_font_une_seule_carte():
    """**La source s'écrit parfois de deux façons.** « Prepare For Takeoff » et
    « Prepare for Takeoff » sont la même carte, et faisaient deux `oracle_id` :
    un seul cas sur 2 181, mais il coûtait une carte introuvable à la
    résolution des decklists — le nom devenant ambigu, il était écarté par
    prudence.

    C'est la leçon Riftbound sous une autre forme : *une identité ne se dérive
    pas d'un champ d'affichage*."""
    a = entry(name="Prepare For Takeoff", subtitle="", type="Event")
    b = entry(name="Prepare for Takeoff", subtitle="", type="Event", set_code="LOF")
    fusionnees = canonicalise([a, b])
    assert len({e.oracle_id for e in fusionnees}) == 1
    assert len(fold_cards(fusionnees)) == 1


def test_la_forme_retenue_est_la_premiere_rencontree():
    """Et non une forme reconstruite : le titre affiché doit rester celui que
    la source publie."""
    a = entry(name="Prepare For Takeoff", subtitle="", type="Event")
    b = entry(name="Prepare for Takeoff", subtitle="", type="Event", set_code="LOF")
    assert fold_cards(canonicalise([a, b]))[0].name == "Prepare For Takeoff"
    assert fold_cards(canonicalise([b, a]))[0].name == "Prepare for Takeoff"


def test_la_canonicalisation_ne_fusionne_pas_deux_cartes_differentes():
    """Elle ne réunit que ce qui ne diffère **que** par la casse ou la
    ponctuation. Deux titres distincts restent distincts, et un même titre
    porté par deux types aussi — « Snapshot Reflexes » est un Event et un
    Upgrade."""
    a = entry(name="Data Vault", subtitle="Scarif")
    b = entry(name="Data Vault", subtitle="Jedha")
    assert len({e.oracle_id for e in canonicalise([a, b])}) == 2

    ev = entry(name="Snapshot Reflexes", subtitle="", type="Event")
    up = entry(name="Snapshot Reflexes", subtitle="", type="Upgrade")
    assert len({e.oracle_id for e in canonicalise([ev, up])}) == 2
