"""Le connecteur de catalogue Lorcana, sur des entrées figées.

Aucun appel réseau. Ce qui est éprouvé ici est la lecture d'une entrée, et les
quatre décisions qu'elle porte : l'identité, le nom affiché, l'encre, et la
finition — cette dernière étant la seule à pouvoir rendre une carte
**insaisissable** si elle se trompe.
"""

from __future__ import annotations

from decimal import Decimal

from app.ingestion.lorcast_ingest import (
    NAMESPACE,
    full_name,
    inks_of,
    money,
    parse,
    type_line,
)


def entree(**surcharges) -> dict:
    """Une carte telle que Lorcast la publie."""
    base = {
        "id": "crd_d9f3b86af85f48579ed9d0d7ce0de129",
        "name": "Ariel",
        "version": "On Human Legs",
        "layout": "normal",
        "cost": 4,
        "ink": "Amber",
        "inks": None,
        "type": ["Character"],
        "classifications": ["Storyborn", "Hero", "Princess"],
        "text": "VOICELESS This character can't {E} to sing songs.",
        "rarity": "Uncommon",
        "collector_number": "1",
        "lang": "en",
        "prices": {"usd": "0.09", "usd_foil": "0.65"},
        "set": {"code": "1", "name": "The First Chapter"},
        "image_uris": {"digital": {"normal": "https://cards.lorcast.io/x/normal.avif"}},
    }
    base.update(surcharges)
    return base


def test_l_identite_vient_de_la_source_et_non_du_nom():
    """La leçon de Pokémon, qui se répète : 1 910 cartes partagent leur nom.

    Deux « Mickey Mouse » de versions différentes doivent porter deux identités.
    """
    un, _ = parse(entree(id="crd_aaa", name="Mickey Mouse", version="Brave Little Tailor"))
    deux, _ = parse(entree(id="crd_bbb", name="Mickey Mouse", version="True Friend"))

    assert un.oracle_id != deux.oracle_id


def test_l_identite_est_deterministe():
    """Deux ingestions successives ne doivent pas dupliquer le catalogue."""
    un, tirage_un = parse(entree())
    deux, tirage_deux = parse(entree())

    assert un.oracle_id == deux.oracle_id
    assert tirage_un.key == tirage_deux.key
    assert tirage_un.illustration_id == tirage_deux.illustration_id


def test_l_identite_du_tirage_differe_de_celle_de_la_carte():
    """Sinon une impression écraserait sa carte dans une table voisine."""
    carte, tirage = parse(entree())

    assert tirage.oracle_id == carte.oracle_id
    assert tirage.key != carte.oracle_id
    assert tirage.illustration_id != tirage.key


def test_le_nom_porte_le_sous_titre():
    assert full_name(entree()) == "Ariel - On Human Legs"
    assert full_name(entree(version="")) == "Ariel"
    assert full_name(entree(version=None)) == "Ariel"


def test_la_ligne_de_type_se_lit_comme_celle_de_magic():
    """`CardRole` lit le premier mot chez cinq jeux sur sept."""
    assert type_line(entree()).startswith("Character")
    assert type_line(entree()) == "Character — Storyborn, Hero, Princess"
    assert type_line(entree(classifications=[])) == "Character"
    assert type_line(entree(type=["Location"], classifications=[])) == "Location"


def test_les_deux_encres_se_lisent():
    """`inks` porte les bi-encre, `ink` les autres.

    Ne lire que le premier laisserait 160 cartes sans encre par construction
    plutôt que par constat.
    """
    assert inks_of(entree()) == ("Amber",)
    assert inks_of(entree(inks=["Amber", "Steel"])) == ("Amber", "Steel")
    assert inks_of(entree(ink=None, inks=None)) == ()
    assert inks_of(entree(ink=None, inks=[])) == ()


def test_la_finition_se_lit_sur_la_presence_de_la_cle():
    _, deux = parse(entree())
    assert deux.finishes == ("nonfoil", "foil")

    _, brillante_seule = parse(entree(prices={"usd_foil": "12.00"}))
    assert brillante_seule.finishes == ("foil",)

    _, ordinaire_seule = parse(entree(prices={"usd": "0.09"}))
    assert ordinaire_seule.finishes == ("nonfoil",)


def test_une_carte_sans_prix_reste_saisissable():
    """Le contrôle du §6 doit valoir zéro sur les sept jeux.

    68 cartes ne publient aucune des deux clés. Sans finition, `card_editions`
    les refuse dans les deux sens : introuvables à l'ajout, impossibles à ranger
    en classeur. Le repli sur `nonfoil` est sûr — toute carte du jeu existe en
    tirage ordinaire, seule la brillante étant conditionnelle.
    """
    _, tirage = parse(entree(prices={}))

    assert tirage.finishes == ("nonfoil",)
    assert tirage.usd is None
    assert tirage.usd_foil is None


def test_une_carte_qui_n_existe_qu_en_brillante_ne_gagne_pas_l_ordinaire():
    """12,7 % du catalogue est dans ce cas — les Enchanted et compagnie.

    Leur ajouter `nonfoil` d'office les rendrait achetables dans une finition
    qui n'existe pas, et une collection les compterait à zéro euro.
    """
    _, tirage = parse(entree(prices={"usd_foil": "290.51"}))

    assert "nonfoil" not in tirage.finishes
    assert tirage.finishes == ("foil",)


def test_un_prix_nul_n_est_pas_une_absence():
    """Une carte cotée 0,00 $ est cotée ; une carte sans clé ne l'est pas."""
    assert money("0.00") == Decimal("0.00")
    assert money("0") == Decimal("0")
    assert money(None) is None
    assert money("") is None
    assert money("pas un prix") is None


def test_le_type_gouverne_le_layout_et_non_le_champ_de_la_source():
    """Les deux disent la même chose sur l'orientation ; seul le type sert au
    dosage, et c'est lui qu'on garde."""
    lieu, _ = parse(entree(type=["Location"], layout="landscape"))
    personnage, _ = parse(entree(layout="normal"))

    assert lieu.layout == "Location"
    assert personnage.layout == "Character"


def test_l_espace_de_nommage_est_propre_au_jeu():
    """Deux sources ne doivent jamais produire la même identité par hasard."""
    import uuid

    from app.ingestion.optcg_ingest import NAMESPACE as ONEPIECE

    assert NAMESPACE != ONEPIECE
    assert uuid.uuid5(NAMESPACE, "x") != uuid.uuid5(ONEPIECE, "x")


# --- l'identité regroupe les rééditions, et rien d'autre ---------------------


def test_une_reedition_rend_la_meme_carte():
    """Cette source ne distingue pas la carte du tirage.

    « Jolly Roger - Hook's Ship » y figure deux fois — promo P1 n°27 et
    extension 3 n°135 —, avec la même illustration. L'index l'a révélé par une
    paire à **1 bit**, deux entrées que la reconnaissance ne pourrait jamais
    départager.
    """
    promo, tirage_promo = parse(
        entree(
            id="crd_promo",
            name="Jolly Roger",
            version="Hook's Ship",
            type=["Location"],
            set={"code": "P1", "name": "Promo Set 1"},
            collector_number="27",
        )
    )
    extension, tirage_ext = parse(
        entree(
            id="crd_ext",
            name="Jolly Roger",
            version="Hook's Ship",
            type=["Location"],
            set={"code": "3", "name": "Into the Inklands"},
            collector_number="135",
        )
    )

    assert promo.oracle_id == extension.oracle_id
    # Mais deux tirages distincts, avec chacun son illustration.
    assert tirage_promo.key != tirage_ext.key
    assert tirage_promo.illustration_id != tirage_ext.illustration_id


def test_deux_cartes_aux_statistiques_differentes_ne_fusionnent_pas():
    """39 groupes fusionnaient sous `nom + version` seuls — le défaut Yu-Gi-Oh.

    Les statistiques sont ce qui les sépare, et c'est mesuré : la clé retenue
    laisse **zéro** groupe divergent, contre 39 pour `nom + version` et 22 en y
    ajoutant le coût.
    """
    base = dict(name="Stitch", version="Rock Star", type=["Character"])
    une, _ = parse(entree(id="a", cost=4, **base))
    autre, _ = parse(entree(id="b", cost=7, **base))

    assert une.oracle_id != autre.oracle_id


def test_le_texte_n_entre_pas_dans_l_identite():
    """La source le reformule d'une réédition à l'autre.

    « Shift 4 (You may pay 4 {I} to play this on top of one of your Stitch
    characters.) » devient « … one of your characters named Stitch. » puis
    « Shift 4 {I} (… ». L'inclure produirait 3 192 identités, donc aucun
    regroupement — exactement le défaut qu'on cherche à éviter.
    """
    base = dict(name="Stitch", version="Rock Star", type=["Character"], cost=4)
    une, _ = parse(entree(id="a", text="Shift 4 (… your Stitch characters.)", **base))
    autre, _ = parse(
        entree(id="b", text="Shift 4 {I} (… your characters named Stitch.)", **base)
    )

    assert une.oracle_id == autre.oracle_id


def test_l_identifiant_de_la_source_reste_celui_du_tirage():
    """C'est son rôle naturel : opaque et stable, il désigne une impression."""
    _, un = parse(entree(id="crd_aaa"))
    _, deux = parse(entree(id="crd_bbb"))

    assert un.key != deux.key
