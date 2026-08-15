"""Ce que le connecteur Wankul décide sans la source.

Ces tests portent sur la moitié du connecteur qui ne dépend d'aucun réseau :
l'identité d'une carte et ce qui est rangé dans quelle colonne. C'est là que les
quatre jeux précédents ont perdu du temps — un prix pris pour une cote, un nom
pris pour une identité, un champ d'affichage pris pour une clé — et c'est
testable avant que la première requête ne soit écrite.
"""

from __future__ import annotations

from app.ingestion.wankul_ingest import (
    EXPECTED_CARDS,
    EXPECTED_TOTAL,
    GAME,
    WankulCard,
    card_from,
    fetch_all,
    media_uuid,
    orientation_of,
    write_cards,
    write_prints,
    write_search_names,
)

#: Deux identifiants de fichier, tels que la source les publie dans ses chemins
#: de rendu. Ils sont différents pour une même carte : le paysage est un autre
#: fichier que le principal, et c'est tout l'enjeu du test qui les sépare.
UUID_MAIN = "b4372ef1-1c81-4d21-a91e-2c281cf86103"
UUID_PAYSAGE = "2b6f1a67-3898-45dc-829b-77ad8c71920f"


def carte(**kw) -> WankulCard:
    base = dict(
        source_id=78,
        number="78",
        name="Mort-Vivant",
        set_code="ORIGINS",
        type_line="Personnage",
        rarity="Rare",
        effigy="Laink",
    )
    base.update(kw)
    return WankulCard(**base)


class ConnexionFactice:
    """Retient ce qu'on lui donne à écrire, sans base derrière."""

    def __init__(self) -> None:
        self.rows: list[tuple] = []
        self.commits = 0

    def cursor(self):
        conn = self

        class _Curseur:
            def __enter__(self):
                return self

            def __exit__(self, *_):
                return False

            def execute(self, _statement, row):
                conn.rows.append(row)

        return _Curseur()

    def commit(self) -> None:
        self.commits += 1


# --- l'identite ne se derive pas du nom -------------------------------------


def test_deux_effigies_du_meme_nom_sont_deux_cartes():
    """**La leçon Pokémon, appliquée avant d'en payer le prix.** Là-bas, 92 % du
    catalogue partageait son nom avec une autre carte — 112 Pikachu — et dériver
    l'identité du nom les aurait fusionnés. Wankul imprime le même personnage
    sous deux effigies : `mort_vivant_laink` et `mort_vivant_terracid` portent le
    même nom et sont deux cartes distinctes."""
    laink = carte(source_id=78, effigy="Laink")
    terracid = carte(source_id=79, effigy="Terracid")

    assert laink.name == terracid.name
    assert laink.oracle_id != terracid.oracle_id


def test_le_meme_numero_dans_deux_extensions_ne_se_confond_pas():
    """Les numérotations recommencent à chaque extension : le numéro seul ne
    peut pas être la clé."""
    origins = carte(source_id=1, set_code="ORIGINS", number="1")
    saison2 = carte(source_id=2, set_code="S02", number="1")

    assert origins.oracle_id != saison2.oracle_id


def test_l_identite_est_stable_d_une_course_a_l_autre():
    """Elle est dérivée, donc reproductible : une réingestion doit remplacer la
    carte, pas en créer une seconde. Sans quoi chaque course doublerait la
    collection de l'utilisateur."""
    assert carte().oracle_id == carte().oracle_id
    # Ce qui ne participe pas à la clé ne doit pas la déplacer.
    assert carte().oracle_id == carte(name="Autre nom", rarity="Commune").oracle_id


# --- ce qui est range ou, et ce qui reste vide -------------------------------


def test_les_colonnes_de_magic_restent_vides():
    """**Wankul n'a ni couleur ni coût d'invocation.** Y ranger un analogue de
    forme referait l'erreur mesurée sur Yu-Gi-Oh, où l'Attribut logé dans
    `color_identity` aurait écarté 32 % du catalogue sur une règle inexistante."""
    conn = ConnexionFactice()
    write_cards(conn, [carte()])

    (row,) = conn.rows
    # L'ordre suit la requête : oracle_id, name, type_line, oracle_text,
    # color_identity, legalities, layout, game.
    assert row[4] == [], "l'identité de couleur doit rester vide"
    assert row[7] == GAME


def test_l_orientation_tient_lieu_de_disposition_et_non_l_effigie():
    """**Correction établie sur pièces.** Ce module rangeait d'abord l'effigie
    dans `layout`. Deux cartes ont montré que c'est faux : « Road Trip » est
    horizontale et porte son illustration en plein cadre, textes superposés ;
    « Braqueur » est verticale et porte une illustration encadrée, de 0,045 à
    0,672 de sa hauteur. Ce ne sont pas deux rotations d'une même maquette, ce
    sont deux mises en page — et c'est l'orientation qui les distingue, comme
    chez Riftbound. L'API du Wankuldex publie d'ailleurs ce champ.

    L'effigie reste une information de contenu : de quel personnage la carte
    porte le visage, ce qui ne décide d'aucun découpage."""
    conn = ConnexionFactice()
    write_cards(conn, [carte(orientation="horizontal", effigy="Terracid")])

    (row,) = conn.rows
    assert row[6] == "horizontal"


def test_l_orientation_se_deduit_du_rendu_et_non_du_champ_homonyme():
    """**Le champ `orientation` de la source ment, et c'est mesuré.**
    `?orientation=horizontal` rend 40 cartes dont 13 sont debout : les promos
    PGW 2023, 2024, 2025 et une Édition Spéciale. Trois d'entre elles ont été
    confrontées à leur rendu — 751 x 1059, des cartes verticales.

    Ce qui sépare réellement les deux maquettes est la présence d'un rendu
    paysage : les 27 Terrains du lot en ont un, aucune des 13 autres.
    """
    terrain = {"name": "NAVIRE PIRATE", "imagePaysage": "/…_paysage.jpg",
               "imageUrl": "/…_main.jpg"}
    promo = {"name": "CHIEN - PGW 2024", "imagePaysage": None,
             "imageUrl": "/…_main.jpg"}

    assert orientation_of(terrain) == "horizontal"
    assert orientation_of(promo) == "vertical", (
        "une promo PGW est annoncée horizontale par la source et imprimée debout"
    )


def test_le_volume_attendu_couvre_les_six_extensions():
    """Garde-fou de complétude : une course qui rendrait nettement moins a
    rencontré un mur, et le journal doit le dire plutôt que d'enregistrer un
    catalogue amputé — le défaut qui a coûté 93 decks sur Yu-Gi-Oh."""
    assert len(EXPECTED_CARDS) == 6
    assert EXPECTED_TOTAL == 958


def test_une_carte_citee_deux_fois_n_est_ecrite_qu_une_fois():
    """Une source qui sert la même carte sous deux entrées ne doit pas produire
    deux lignes : l'écriture est idempotente dans la course comme entre deux."""
    conn = ConnexionFactice()
    written = write_cards(conn, [carte(), carte(), carte(source_id=79)])

    assert written == 2
    assert conn.commits == 1


# --- la lecture n'est pas branchee, et le dit ------------------------------


class ReponseFactice:
    def __init__(self, status_code: int, payload: dict) -> None:
        self.status_code = status_code
        self._payload = payload

    def json(self) -> dict:
        return self._payload


class ClientFactice:
    """Rejoue des réponses préparées et retient ce qu'on lui a demandé.

    **Aucun test de ce dépôt ne touche le réseau.** Une première version de ces
    tests appelait `fetch_all` sans client : elle a tiré 879 cartes de la source
    et duré 95 secondes. Un test qui sort de la machine n'est plus un test — il
    devient lent, non reproductible, et il consomme le débit d'un tiers.
    """

    def __init__(self, reponses: list) -> None:
        self.reponses = list(reponses)
        self.appels: list[dict] = []

    def get(self, url, params=None):
        self.appels.append({"url": url, "params": params or {}})
        return self.reponses.pop(0) if self.reponses else ReponseFactice(
            200, {"data": [], "meta": {"total": 0}})


def payload_carte(num: str, nom: str, paysage: bool = False) -> dict:
    dossier = f"/apps/wankul/api/media/saison/01-origins/{num}-{nom.lower()}"
    return {
        "id": int(num), "name": nom, "number": num,
        "effigy": {"name": "Laink", "slug": "laink"},
        "imageUrl": f"{dossier}/{UUID_MAIN}_main.jpg",
        "imagePaysage": f"{dossier}/{UUID_PAYSAGE}_paysage.jpg" if paysage else None,
        "set": {"name": "Origins", "slug": "origins"},
        "rarity": {"name": "Commune", "slug": "commune"},
        "artist": {"name": "Jaycee"},
    }


def test_un_503_est_retente_et_finit_par_passer():
    """La source rend des 503 **intermittents** : un seul sur trente lots lors
    de la course d'essai, et il a coûté 79 cartes. Sans reprise, une extension
    entière manque et le total ne le dit qu'après coup."""
    client = ClientFactice([
        ReponseFactice(200, {"data": [{"slug": "laink"}]}),   # effigies
        ReponseFactice(503, {}),                              # 1er lot, refusé
        ReponseFactice(200, {"data": [payload_carte("1", "NAVIRE")],
                             "meta": {"total": 1}}),
    ])

    cartes = fetch_all(sleep=lambda _: None, client=client)

    assert [c.name for c in cartes] == ["NAVIRE"]
    # Le premier lot a reçu un 503 puis a été redemandé : deux appels pour le
    # même couple extension-effigie, là où les suivants n'en ont qu'un.
    premier = [a for a in client.appels
               if a["params"].get("set") == "origins"
               and a["params"].get("effigy") == "laink"]
    assert len(premier) == 2, f"lot non redemandé après 503 : {premier}"


def test_le_type_se_deduit_du_rendu_paysage():
    """La source ne publie aucun champ de type : « Terrain » y est à la fois une
    rareté et une effigie, et ni l'une ni l'autre ne suffit — « Ouverture de
    Colis » est un Terrain (T#201) de rareté « Edition Gold ». Le rendu paysage
    ne suit que la maquette, et la maquette suit le type."""
    assert card_from(payload_carte("1", "NAVIRE", paysage=True)).type_line \
        == "Terrain"
    assert card_from(payload_carte("2", "BRAQUEUR")).type_line == "Personnage"


# --- les impressions : ce qui va dans quelle colonne -------------------------


def test_l_oeuvre_est_identifiee_par_le_rendu_principal_jamais_le_paysage():
    """**Le seul lien entre une impression et le fichier qu'on possède.**

    Les illustrations Wankul ne sont pas téléchargeables — `403 Hotlinking not
    allowed` (§IV.10) —, l'index d'empreintes est donc bâti depuis un dossier
    local qui ne contient que les rendus `_main`. Prendre l'identifiant du
    paysage sur un Terrain paraîtrait plus juste, puisque c'est le rendu que
    `art_crop_url` désigne : ce serait 146 cartes introuvables dans le dossier,
    et un index amputé sans que rien ne le dise.
    """
    terrain = card_from(payload_carte("1", "RADEAU", paysage=True))

    assert str(terrain.illustration_id) == UUID_MAIN
    assert str(terrain.illustration_id) != UUID_PAYSAGE


def test_l_url_affichee_montre_la_carte_dans_son_sens_de_lecture():
    """Un Terrain est couché : son rendu principal est stocké debout, tourné
    d'un quart de tour. L'afficher ainsi ferait lire son texte de bas en haut."""
    terrain = card_from(payload_carte("1", "RADEAU", paysage=True))
    personnage = card_from(payload_carte("2", "BRAQUEUR"))

    assert terrain.art_url.endswith(f"{UUID_PAYSAGE}_paysage.jpg")
    assert personnage.art_url.endswith(f"{UUID_MAIN}_main.jpg")
    # Absolue : la source publie des chemins relatifs, inutilisables tels quels.
    assert terrain.art_url.startswith("https://wankul.fr/")


def test_une_url_sans_identifiant_ne_produit_pas_de_cle_inventee():
    """Mieux vaut un manque, que `main` compte et annonce, qu'une clé dérivée
    d'une URL dont la forme aurait changé — laquelle rattacherait l'empreinte à
    un fichier qui n'existe pas."""
    assert media_uuid(None) is None
    assert media_uuid("/media/origins/031-garagiste/vignette.jpg") is None


def test_l_impression_ne_porte_ni_prix_ni_identifiant_marchand():
    """**Wankul n'a aucun marché secondaire coté** : le jeu se vend en direct
    par son éditeur (§IV.10). Ranger un zéro se lirait « cette carte ne vaut
    rien » là où la vérité est « personne ne la cote »."""
    conn = ConnexionFactice()
    write_prints(conn, [card_from(payload_carte("1", "RADEAU", paysage=True))])

    (row,) = conn.rows
    # scryfall_id, oracle_id, lang, printed_name, set_code, set_name,
    # collector_number, rarity, art_crop_url, illustration_id — et rien d'autre.
    assert len(row) == 10
    assert row[2] == "fr", "un jeu français annoncé anglais fausse l'affichage"
    assert row[4] == "origins" and row[5] == "Origins"


def test_l_impression_ne_se_confond_pas_avec_la_carte():
    """Une carte, une impression — Wankul ne réédite pas —, mais deux clés :
    `card_prints` est ce que le classeur et le choix d'édition interrogent."""
    carte_ = card_from(payload_carte("1", "RADEAU"))

    assert carte_.print_id != carte_.oracle_id
    assert carte_.print_id == card_from(payload_carte("1", "RADEAU")).print_id


def test_une_carte_citee_deux_fois_ne_produit_qu_une_impression():
    conn = ConnexionFactice()
    written = write_prints(conn, [card_from(payload_carte("1", "RADEAU"))] * 2)

    assert written == 1
    assert conn.commits == 1


# --- l'index de saisie ------------------------------------------------------


def test_les_noms_sont_indexes_sinon_rien_n_est_trouvable():
    """**Le défaut ne se voyait pas depuis `cards`, qui était pleine.** Toutes
    les recherches du dépôt passent par `card_search_names` : 958 cartes en base
    et zéro ligne ici, c'est un catalogue qu'on ne peut pas saisir."""
    conn = ConnexionFactice()
    written = write_search_names(conn, [card_from(payload_carte("1", "RADEAU"))])

    (row,) = conn.rows
    assert written == 1
    assert row[1] == "RADEAU" and row[2] == "radeau" and row[3] == "fr"


def test_deux_cartes_du_meme_nom_sont_indexees_toutes_les_deux():
    """« MORT-VIVANT » existe sous deux effigies : l'unicité porte sur le couple
    carte-nom, pas sur le nom, et la recherche doit rendre les deux."""
    conn = ConnexionFactice()
    a = card_from(payload_carte("78", "MORT-VIVANT"))
    b = card_from(payload_carte("79", "MORT-VIVANT"))

    assert write_search_names(conn, [a, b]) == 2
