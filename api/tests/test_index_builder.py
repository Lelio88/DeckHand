"""Ce que le constructeur d'index compose, et ce qu'il refuse de hacher."""

from __future__ import annotations

from app.vision.index_builder import image_url, pending_prints


def test_une_url_tcgdex_est_completee_par_sa_qualite():
    """Servie nue, elle rend 404 : la source exige une qualité et une extension."""
    assert (
        image_url("https://assets.tcgdex.net/en/base/base4/1", "pokemon")
        == "https://assets.tcgdex.net/en/base/base4/1/high.png"
    )


def test_les_urls_deja_completes_ne_sont_pas_touchees():
    """Scryfall et Riftcodex servent des URL utilisables telles quelles ; y
    ajouter un suffixe les casserait."""
    scryfall = "https://cards.scryfall.io/art_crop/front/a/b/abc.jpg"
    for game in ("magic", "riftbound", "yugioh"):
        assert image_url(scryfall, game) == scryfall


class ConnexionQuiRetientLaRequete:
    """Retient la requête au lieu de l'exécuter.

    La vérifier contre une vraie base demanderait un serveur, là où ce qui
    compte est qu'aucune réécriture ne fasse disparaître une clause.
    """

    def cursor(self):
        return self

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False

    def execute(self, query, args=()):
        self.query = query
        self.args = args
        return self

    def fetchall(self):
        return []


def test_les_energies_de_base_sont_ecartees_de_la_selection():
    """**Le garde-fou chiffré.** 97,1 % ont une jumelle sous le seuil de
    confiance et 12 % seraient annoncées à tort avec assurance : elles ne doivent
    jamais entrer dans l'index."""
    conn = ConnexionQuiRetientLaRequete()
    pending_prints(conn)

    assert "layout IS DISTINCT FROM 'energy'" in conn.query


def test_la_selection_ecarte_les_impressions_sans_illustration_id():
    """Sans lui, rien ne dit si leur image a déjà été hachée."""
    conn = ConnexionQuiRetientLaRequete()
    pending_prints(conn)

    assert "p.illustration_id IS NOT NULL" in conn.query


def test_la_selection_rend_l_identifiant_d_oeuvre():
    """**C'est lui qui désigne le fichier**, pour le constructeur d'index local :
    l'URL d'affichage ne le fait pas toujours — chez Wankul, un Terrain y porte
    son rendu paysage, absent du dossier."""
    conn = ConnexionQuiRetientLaRequete()
    pending_prints(conn)

    assert "p.illustration_id::text" in conn.query


def test_la_selection_peut_se_borner_a_un_jeu():
    """Sans ce filtre, l'index local réclamerait des fichiers absents pour les
    65 000 illustrations des autres jeux, et son rapport ne dirait plus rien."""
    conn = ConnexionQuiRetientLaRequete()
    pending_prints(conn, game="wankul")

    assert "c.game = %s" in conn.query
    assert conn.args == ("wankul",)

    sans_filtre = ConnexionQuiRetientLaRequete()
    pending_prints(sans_filtre)
    assert "c.game = %s" not in sans_filtre.query
    assert sans_filtre.args == ()
