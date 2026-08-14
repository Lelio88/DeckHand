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


def test_les_energies_de_base_sont_ecartees_de_la_selection():
    """**Le garde-fou chiffré.** 97,1 % ont une jumelle sous le seuil de
    confiance et 12 % seraient annoncées à tort avec assurance : elles ne doivent
    jamais entrer dans l'index. La requête est lue plutôt qu'exécutée — la
    vérifier contre une vraie base demanderait un serveur, là où ce qui compte
    est qu'aucune réécriture ne fasse disparaître la clause."""
    class ConnexionQuiRetientLaRequete:
        def cursor(self):
            return self

        def __enter__(self):
            return self

        def __exit__(self, *_):
            return False

        def execute(self, query):
            self.query = query
            return self

        def fetchall(self):
            return []

    conn = ConnexionQuiRetientLaRequete()
    pending_prints(conn)

    assert "layout IS DISTINCT FROM 'energy'" in conn.query


def test_la_selection_ecarte_les_impressions_sans_illustration_id():
    """Sans lui, rien ne dit si leur image a déjà été hachée."""
    class Conn:
        def cursor(self):
            return self

        def __enter__(self):
            return self

        def __exit__(self, *_):
            return False

        def execute(self, query):
            self.query = query
            return self

        def fetchall(self):
            return []

    conn = Conn()
    pending_prints(conn)

    assert "p.illustration_id IS NOT NULL" in conn.query
