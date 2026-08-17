"""Tests des bancs de mesure Star Wars Unlimited.

**Un banc faux est pire qu'un banc absent** : il produit des chiffres, on les
écrit dans la doc, et on décide sur eux. Ceux-ci vérifient la mécanique sur des
figures dont la réponse est connue d'avance, sans réseau ni source.

Chaque cas correspond à un défaut réellement rencontré pendant la mesure, ou à
une propriété dont un résultat écrit dépend directement.
"""

from __future__ import annotations

from typing import Any

import numpy as np

from app.measure.pokemon_art_window import Stack
from app.measure.swu_art_window import (
    CANONICAL_LAID,
    CANONICAL_UPRIGHT,
    PROBE_BY_TYPE,
    Group,
    derive,
)
from app.measure.swu_decks import TitleIndex, aspects_of, normalise
from app.measure.swu_taxonomy import Print
from app.measure.swumetastats_probe import PAGE_SIZE, DeckProbe


def impression(**kwargs: Any) -> Print:
    defaults: dict[str, Any] = dict(
        set_code="SOR",
        number="001",
        name="Director Krennic",
        subtitle="Aspiring to Authority",
        type="Leader",
        variant="Normal",
        cid="8560666697",
        rarity="Rare",
        double_sided=True,
        tcgplayer_id="540122",
        front_art="https://exemple/SOR/001.png",
        foil_price="",
    )
    defaults.update(kwargs)
    return Print(**defaults)


# --- la finition, qui se cache dans un champ qui porte autre chose -----------


def test_le_suffixe_foil_marque_la_finition_et_le_reste_est_un_traitement():
    """`VariantType` mêle deux notions. Les confondre gonflerait `card_prints`
    de moitié : `Hyperspace Foil` n'est pas une impression de plus, c'est la
    case brillante de `Hyperspace` — et les deux partagent leur `tcgplayerId`,
    ce que la mesure a confirmé 216 fois sur la seule extension SOR."""
    assert impression(variant="Hyperspace Foil").is_foil
    assert impression(variant="Hyperspace Foil").treatment == "Hyperspace"
    assert impression(variant="Foil").is_foil
    # `Foil` seul est la brillante de `Normal`, et non celle d'un traitement
    # sans nom : la source rompt ici sa propre règle de suffixe, et 1 148
    # impressions en dépendent.
    assert impression(variant="Foil").treatment == "Normal"


def test_un_traitement_ordinaire_n_est_pas_brillant():
    """`Prestige Serialized` contient un mot en plus, pas le suffixe. Chercher
    « Foil » n'importe où dans la valeur classerait des traitements ordinaires
    parmi les brillants."""
    for value in ("Normal", "Hyperspace", "Showcase", "Prestige Serialized", "OP Promo"):
        assert not impression(variant=value).is_foil, value
        assert impression(variant=value).treatment == value


# --- le périmètre : ce qui se joue ------------------------------------------


def test_un_jeton_se_reconnait_a_son_type_pas_a_son_extension():
    """Mesuré : l'extension `GG` (Gamegenic) contient des jetons alors que son
    nom ne porte pas « Tokens », et `TASH` porte le mot sans qu'aucun type ne le
    dise. Le type est un vocabulaire, le nom d'extension un libellé."""
    assert impression(type="Token Upgrade", set_code="GG").is_token
    assert not impression(type="Upgrade", set_code="TSOR").is_token


def test_l_identite_d_une_carte_est_son_titre_imprime():
    """Deux impressions d'un même titre dans deux extensions sont une seule
    carte — 320 titres du catalogue sont dans ce cas, par les promos OP."""
    a = impression(set_code="LOF", number="012")
    b = impression(set_code="P25", number="004", variant="OP Promo")
    assert a.card_key == b.card_key


# --- la pagination, et son piège silencieux ---------------------------------


class FakeDeckProbe(DeckProbe):
    """Sonde qui rend des pages décidées d'avance, sans réseau ni cache."""

    def __init__(self, pages: dict[int, list[dict[str, Any]]]) -> None:
        self.pages = pages
        self.asked: list[int] = []
        self.requests = 0

    def _page(self, start: str, end: str, skip: int) -> dict[str, Any]:
        self.asked.append(skip)
        return {"decklists": self.pages.get(skip, []), "totalCount": 999}


def deck(identifier: int) -> dict[str, Any]:
    return {"id": identifier, "cards": []}


def test_la_pagination_avance_par_skip():
    probe = FakeDeckProbe({0: [deck(1), deck(2)], PAGE_SIZE: [deck(3)], 2 * PAGE_SIZE: []})
    assert [d["id"] for d in probe.decklists("a", "b")] == [1, 2, 3]
    assert probe.asked == [0, PAGE_SIZE, 2 * PAGE_SIZE]


def test_une_source_qui_ignore_skip_arrete_la_boucle_au_lieu_de_tourner():
    """Le piège mesuré : `limit`, `page` et `offset` sont ignorés par cette
    source, qui rend la première page sans broncher. Si `skip` cessait de
    l'être à son tour, une boucle naïve réécrirait vingt decks à l'infini sans
    jamais échouer — et le connecteur annoncerait un corpus qu'il n'a pas."""
    same = [deck(1), deck(2)]
    probe = FakeDeckProbe({0: same, PAGE_SIZE: same, 2 * PAGE_SIZE: same})
    assert [d["id"] for d in probe.decklists("a", "b")] == [1, 2]
    assert probe.asked == [0, PAGE_SIZE]


def test_le_plafond_arrete_la_lecture():
    probe = FakeDeckProbe({0: [deck(1), deck(2), deck(3)]})
    assert len(list(probe.decklists("a", "b", limit=2))) == 2


# --- les aspects, qui décident du filtrage du pool --------------------------


def test_les_aspects_se_lisent_sur_une_liste_separee_par_des_virgules():
    assert aspects_of({"aspect": "Cunning, Heroism"}) == {"Cunning", "Heroism"}
    assert aspects_of({"aspect": "Vigilance"}) == {"Vigilance"}


def test_une_carte_sans_aspect_n_en_declare_aucun():
    """Elle est jouable partout sans pénalité : la compter comme « hors
    aspect » ferait croire à une contrainte relâchée qui n'existe pas."""
    assert aspects_of({"aspect": ""}) == set()
    assert aspects_of({}) == set()
    assert aspects_of(None) == set()


# --- la résolution des citations, en trois temps ----------------------------


def index() -> TitleIndex:
    """Un catalogue de poche, avec les trois cas mesurés sur le vrai."""
    entries = [
        ("Black One", "Scourge of Starkiller Base"),  # nom porté par 2 cartes
        ("Black One", "Straight At Them"),
        ("Data Vault", "Scarif"),                     # base, citée sans sous-titre
        ("Hold For Questioning", ""),                 # casse différente
    ]
    by_full, by_name = {}, {}
    for name, subtitle in entries:
        full = f"{name} | {subtitle}" if subtitle else name
        by_full[normalise(full)] = full
        by_name.setdefault(normalise(name), set()).add(full)
    return TitleIndex(by_full=by_full, by_name=by_name)


def test_la_casse_ne_doit_pas_faire_perdre_une_carte():
    """Elle coûtait 7,35 % des citations : les listes écrivent « Hold for
    Questioning » là où le catalogue publie « Hold For Questioning »."""
    resolved, route = index().resolve("Hold for Questioning")
    assert resolved == "Hold For Questioning"
    assert route == "titre entier"


def test_une_base_citee_sans_son_sous_titre_se_retrouve_par_son_nom():
    """Les listes citent « Data Vault » quand le catalogue publie le nom
    « Data Vault » et le sous-titre « Scarif »."""
    resolved, route = index().resolve("Data Vault")
    assert resolved == "Data Vault | Scarif"
    assert route == "nom seul"


def test_un_nom_porte_par_deux_cartes_reste_ambigu_plutot_que_devine():
    """« Black One » désigne deux cartes réellement différentes. Un repli
    aveugle en choisirait une au hasard et écrirait un deck faux sans que rien
    ne le signale — c'est le faux couple, que nul écran ne détrompe."""
    resolved, route = index().resolve("Black One")
    assert resolved is None
    assert route == "ambigu"


def test_le_titre_entier_l_emporte_sur_le_nom_seul():
    """Sinon le repli mangerait les cartes qu'il devait seulement secourir."""
    resolved, route = index().resolve("Black One | Straight at Them")
    assert resolved == "Black One | Straight At Them"
    assert route == "titre entier"


def test_la_ponctuation_typographique_est_repliee():
    """Les listes citent « Benthic “Two Tubes” » et « Mesa Propose… » là où le
    catalogue emploie des guillemets droits et pas d'ellipse."""
    assert normalise("Benthic “Two Tubes”") == normalise('Benthic "Two Tubes"')
    assert normalise("Mesa Propose…") == normalise("Mesa Propose")
    assert normalise("Rey’s Staff") == normalise("Rey's Staff")


def test_la_normalisation_ne_confond_pas_deux_titres_differents():
    """Le garde-fou : replier la ponctuation doit combler des manques, jamais
    créer de faux couples."""
    assert normalise("Data Vault") != normalise("Data Vaults")
    assert normalise("Black One | Straight At Them") != normalise("Black One")


# --- la fenêtre d'illustration, sur une figure dont la réponse est connue ----


def synthetic_stack(box: tuple[int, int, int, int], laid: bool = False) -> Stack:
    """Une carte de synthèse : un cadre clair, une fenêtre sombre bordée.

    L'image moyenne suffit — c'est la seule chose que `derive` regarde. La
    fenêtre est peinte en gris moyen sur un fond clair, ce qui produit un
    gradient nul partout sauf sur ses quatre bords : exactement la figure que
    l'empilement de vraies cartes fabrique, en propre.
    """
    width, height = CANONICAL_LAID if laid else CANONICAL_UPRIGHT
    mean = np.full((height, width), 220.0, dtype=np.float32)
    left, top, right, bottom = box
    mean[top:bottom, left:right] = 120.0
    return Stack(
        name="synthese",
        count=20,
        mean=mean,
        deviation=np.zeros_like(mean),
        planes=[mean],
        ids=["synthese-1"],
    )


def test_la_fenetre_retrouve_un_rectangle_connu():
    """La mécanique doit rendre le rectangle peint, à un pixel près. Le biais
    d'un pixel en haut et à gauche est celui du gradient arrière, documenté
    dans le banc Pokémon : il va dans le sens sûr — mieux vaut perdre un pixel
    d'illustration qu'en gagner un de cadre, identique sur toutes les cartes."""
    width, height = CANONICAL_UPRIGHT
    box = (80, 200, width - 80, 900)
    window = derive(synthetic_stack(box), PROBE_BY_TYPE['Unit'][0])
    left, top, right, bottom = window.pixels
    assert abs(left - box[0]) <= 1
    assert abs(top - box[1]) <= 1
    assert abs(right - (box[2] - 1)) <= 1
    assert abs(bottom - (box[3] - 1)) <= 1


def test_la_fenetre_est_rendue_en_fractions_de_la_carte():
    """C'est ce qui rend la mesure indépendante de la taille du rendu — et la
    condition pour qu'une normalisation à une taille de référence ne change
    rien au résultat, les treize formats publiés partageant leur rapport à
    0,4 % près."""
    width, height = CANONICAL_UPRIGHT
    window = derive(synthetic_stack((80, 200, width - 80, 900)), PROBE_BY_TYPE['Unit'][0])
    assert 0.0 < window.box.left < window.box.right < 1.0
    assert 0.0 < window.box.top < window.box.bottom < 1.0
    assert abs(window.box.left - 80 / width) < 0.01


def test_une_aretedu_bord_signale_une_fenetre_butee_et_non_trouvee():
    """Le contrôle doit pouvoir échouer, et celui-ci le peut.

    Quand la bande de sondage tombe hors de l'illustration, la plage calme
    s'étend jusqu'au bord du rendu sans qu'aucun trait ne l'arrête : le banc
    rend alors un rectangle qui n'est pas une fenêtre. C'est la figure ci-
    dessous — une illustration peinte tout en bas, sondée en haut."""
    width, _ = CANONICAL_UPRIGHT
    juste = derive(synthetic_stack((80, 200, width - 80, 900)), PROBE_BY_TYPE['Unit'][0])
    assert not juste.touches_border

    butee = derive(synthetic_stack((80, 1200, width - 80, 1400)), PROBE_BY_TYPE['Unit'][0])
    assert butee.touches_border


def test_chaque_type_a_sa_bande_de_sondage():
    """La maquette suit le type, et l'Event **inverse** celle de l'Unit :
    illustration en bas, texte en haut. Sonder l'Event à la bande de l'Unit
    tombait en plein texte, et le banc rendait le pavé comme fenêtre — 16,5
    bits de séparation contre 31, avec une paire à 3 bits."""
    unit_band, unit_x = PROBE_BY_TYPE["Unit"]
    event_band, event_x = PROBE_BY_TYPE["Event"]
    leader_band, leader_x = PROBE_BY_TYPE["Leader"]

    assert unit_band[1] < event_band[0], "les deux bandes doivent être disjointes"
    assert unit_x == event_x == 0.50, "les cartes debout se sondent au centre"
    assert leader_x < 0.50, "une carte couchée porte son illustration à gauche"


def test_un_type_sans_bande_propre_est_signale():
    """Une maquette non prévue, mesurée sous une bande empruntée, rendrait un
    rectangle sans qu'on sache qu'il est emprunté."""
    connu = Group(name="Unit/Normal", kind="Unit", laid=False, prints=[])
    inconnu = Group(name="Vaisseau/Normal", kind="Vaisseau", laid=False, prints=[])
    assert not connu.probe_is_borrowed
    assert inconnu.probe_is_borrowed
    assert inconnu.probe_band == PROBE_BY_TYPE["Unit"][0]


def test_un_tirage_decale_est_disjoint_du_premier():
    """Le contrôle sur échantillon disjoint est ce qui a démasqué, chez
    Pokémon, deux familles mêlées : il n'a de valeur que si les deux lots ne
    partagent aucune carte."""
    prints = [impression(number=f"{i:03d}") for i in range(20)]
    group = Group(name="Unit/Normal", kind="Unit", laid=False, prints=prints)
    premier = {p.number for p in group.draw(8)}
    second = {p.number for p in group.draw(8, offset=8)}
    assert len(premier) == len(second) == 8
    assert premier & second == set()
