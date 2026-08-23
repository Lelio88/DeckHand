"""Où se trouve l'illustration d'une carte Magic *borderless* ?

**Le défaut que ce banc instruit.** Une carte sans bordure porte son illustration
sur toute sa surface ; le projet ne connaît que deux gabarits, `modern` et
`legacy`, taillés pour une carte à cadre. Appliqués à une borderless, ils
découpent à côté — mesuré sur une carte réelle, l'empreinte tombait à 14 bits de
la bonne carte quand le seuil de confiance est à 12, et le gabarit `legacy`
battait `modern` sur une carte moderne, pur hasard entre deux découpages
également faux.

**Pourquoi Magic se mesure autrement que les autres jeux.** Les bancs
`swu_art_window` et consorts déduisent la fenêtre d'une pile d'images, faute de
référence : leurs sources ne publient que la carte entière. Scryfall, lui, publie
**l'illustration seule** (`art_crop`) à côté de la carte (`normal`). La fenêtre
ne se déduit donc pas, elle se **retrouve** : on cherche où l'illustration
s'inscrit dans la carte.

**La corrélation se fait sur les gradients, pas sur les couleurs.** Les deux
images ne sortent pas du même traitement — `art_crop` est recadré dans l'original
haute résolution, `normal` est un rendu complet, et leurs balances diffèrent
légèrement. Comparer des luminances ferait glisser l'optimum ; comparer où
*varie* l'image, non.

Usage :
    .venv/Scripts/python -m app.measure.magic_art_window
    .venv/Scripts/python -m app.measure.magic_art_window --set msh --size 24
"""

from __future__ import annotations

import argparse
import statistics
import time
from dataclasses import dataclass
from io import BytesIO

import httpx
import numpy as np
from PIL import Image

from app.vision.dhash import dhash, hamming_distance

USER_AGENT = "DeckHand/1.0 (banc de mesure ; contact heianenterpriseyt@gmail.com)"

#: Scryfall demande au plus dix requêtes par seconde ; on reste très en deçà,
#: un banc n'ayant aucune raison de presser une source qu'on ne paie pas.
DELAI = 0.15

#: Largeur de travail pour la corrélation. Assez pour situer la fenêtre au
#: demi-pour-cent, assez peu pour que le balayage reste instantané.
LARGEUR = 240


@dataclass(frozen=True)
class Fenetre:
    """Une fenêtre d'illustration, en fractions de la carte."""

    left: float
    top: float
    right: float
    bottom: float

    def __str__(self) -> str:
        return (
            f"left {self.left:.3f}  top {self.top:.3f}  "
            f"right {self.right:.3f}  bottom {self.bottom:.3f}"
        )


def gradient(image: Image.Image) -> np.ndarray:
    """Amplitude du gradient, normalisée.

    C'est ce qui survit à une différence de rendu entre deux sources : deux
    images de la même illustration varient aux mêmes endroits, même si leurs
    couleurs ne coïncident pas exactement.
    """
    gris = np.asarray(image.convert("L"), dtype=np.float32)
    gx = np.zeros_like(gris)
    gy = np.zeros_like(gris)
    gx[:, 1:-1] = gris[:, 2:] - gris[:, :-2]
    gy[1:-1, :] = gris[2:, :] - gris[:-2, :]
    g = np.abs(gx) + np.abs(gy)
    ecart = g.std()
    return (g - g.mean()) / ecart if ecart > 1e-6 else g


def situer(carte: Image.Image, art: Image.Image) -> tuple[Fenetre, float]:
    """Où l'illustration s'inscrit dans la carte, et la qualité de l'accord.

    Balaye les échelles plausibles : une illustration occupe entre la moitié et
    la totalité de la largeur d'une carte. Pour chacune, la corrélation croisée
    se calcule par produit scalaire glissant — la carte étant petite, le coût est
    négligeable devant le téléchargement.
    """
    carte = carte.resize(
        (LARGEUR, round(LARGEUR * carte.height / carte.width)), Image.LANCZOS
    )
    gc = gradient(carte)

    meilleur: tuple[Fenetre, float] | None = None
    for part in np.arange(0.55, 1.001, 0.01):
        largeur = round(LARGEUR * part)
        hauteur = round(largeur * art.height / art.width)
        if hauteur >= gc.shape[0]:
            continue
        ga = gradient(art.resize((largeur, hauteur), Image.LANCZOS))
        norme = float(np.sqrt((ga * ga).sum()))
        if norme < 1e-6:
            continue

        for y in range(0, gc.shape[0] - hauteur + 1, 2):
            for x in range(0, gc.shape[1] - largeur + 1, 2):
                bloc = gc[y : y + hauteur, x : x + largeur]
                score = float((bloc * ga).sum()) / (
                    norme * float(np.sqrt((bloc * bloc).sum())) + 1e-6
                )
                if meilleur is None or score > meilleur[1]:
                    meilleur = (
                        Fenetre(
                            left=x / gc.shape[1],
                            top=y / gc.shape[0],
                            right=(x + largeur) / gc.shape[1],
                            bottom=(y + hauteur) / gc.shape[0],
                        ),
                        score,
                    )
    assert meilleur is not None
    return meilleur


def cartes(client: httpx.Client, requete: str, taille: int) -> list[dict]:
    """Les impressions que Scryfall rend pour une requête, avec leurs images."""
    trouvees: list[dict] = []
    url = "https://api.scryfall.com/cards/search"
    params = {"q": requete, "unique": "prints"}
    while url and len(trouvees) < taille:
        reponse = client.get(url, params=params, timeout=30)
        reponse.raise_for_status()
        page = reponse.json()
        for carte in page.get("data", []):
            images = carte.get("image_uris")
            if not images or "art_crop" not in images or "normal" not in images:
                continue
            trouvees.append(carte)
            if len(trouvees) >= taille:
                break
        url = page.get("next_page")
        params = None
        time.sleep(DELAI)
    return trouvees


def telecharger(client: httpx.Client, url: str) -> Image.Image:
    reponse = client.get(url, timeout=60, follow_redirects=True)
    reponse.raise_for_status()
    time.sleep(DELAI)
    return Image.open(BytesIO(reponse.content)).convert("RGB")


def mesurer(requete: str, taille: int, titre: str) -> list[Fenetre]:
    with httpx.Client(headers={"User-Agent": USER_AGENT}) as client:
        echantillon = cartes(client, requete, taille)
        print(f"{titre} : {len(echantillon)} impressions")
        if not echantillon:
            return []

        fenetres: list[Fenetre] = []
        for carte in echantillon:
            images = carte["image_uris"]
            try:
                entiere = telecharger(client, images["normal"])
                art = telecharger(client, images["art_crop"])
            except httpx.HTTPError as erreur:
                print(f"  {carte.get('name', '?')[:28]:30s} indisponible ({erreur})")
                continue
            fenetre, score = situer(entiere, art)
            fenetres.append(fenetre)
            print(f"  {carte.get('name', '?')[:28]:30s} {fenetre}  accord {score:.3f}")
    return fenetres


def resumer(titre: str, fenetres: list[Fenetre]) -> Fenetre | None:
    if not fenetres:
        print(f"\n{titre} : rien à résumer")
        return None
    med = Fenetre(
        left=statistics.median(f.left for f in fenetres),
        top=statistics.median(f.top for f in fenetres),
        right=statistics.median(f.right for f in fenetres),
        bottom=statistics.median(f.bottom for f in fenetres),
    )
    print(f"\n{titre} — médiane sur {len(fenetres)} : {med}")
    # L'écart dit si la fenêtre est une propriété du cadre ou de la carte : une
    # dispersion large signifierait qu'il n'y a pas *un* gabarit à trouver.
    for nom, valeurs in (
        ("left", [f.left for f in fenetres]),
        ("top", [f.top for f in fenetres]),
        ("right", [f.right for f in fenetres]),
        ("bottom", [f.bottom for f in fenetres]),
    ):
        if len(valeurs) > 1:
            print(
                f"    {nom:6s} écart-type {statistics.stdev(valeurs):.3f}"
                f"  [{min(valeurs):.3f} – {max(valeurs):.3f}]"
            )
    return med


def sur_photo(chemin: str, carte: str) -> None:
    """Où l'illustration d'une carte connue se trouve dans une photo réelle.

    **Le test décisif de la reconnaissance.** Quand une empreinte tombe à
    quatorze bits de la bonne carte, deux causes restent possibles : le gabarit
    découpe au mauvais endroit, ou le quadrilatère détecté est imprécis. La
    première se mesure sur les rendus de l'éditeur ; la seconde exige de savoir
    où l'illustration est *vraiment* dans la photo — ce que la corrélation dit,
    puisqu'on dispose de l'illustration de référence.
    """
    with httpx.Client(headers={"User-Agent": USER_AGENT}) as client:
        reponse = client.get(
            "https://api.scryfall.com/cards/search",
            params={"q": f'!"{carte}" lang:en', "unique": "prints"},
            timeout=30,
        )
        reponse.raise_for_status()
        entrees = [
            c for c in reponse.json().get("data", []) if c.get("image_uris")
        ]
        if not entrees:
            print(f"aucune impression pour « {carte} »")
            return
        photo = Image.open(chemin).convert("RGB")
        print(f"photo {photo.width}x{photo.height} — {len(entrees)} impressions")
        for entree in entrees:
            art = telecharger(client, entree["image_uris"]["art_crop"])
            fenetre, score = situer(photo, art)
            marque = entree.get("set", "?")
            numero = entree.get("collector_number", "?")

            # **Le plancher que la détection ne peut pas franchir.** Découper la
            # photo à la fenêtre *réelle* — celle que la corrélation vient de
            # situer — donne l'empreinte la meilleure qu'un cadrage parfait
            # produirait. Si elle reste au-delà du seuil de confiance, aucune
            # amélioration de la détection n'y changera rien : ce sont les
            # reflets, la perspective et l'éclairage qui décident.
            w, h = photo.size
            coupe = photo.crop(
                (
                    int(fenetre.left * w),
                    int(fenetre.top * h),
                    int(fenetre.right * w),
                    int(fenetre.bottom * h),
                )
            )
            reference = dhash(art)
            plancher = hamming_distance(dhash(coupe), reference)
            print(
                f"  {marque:5s} {numero:>5s}  {fenetre}  accord {score:.3f}"
                f"  plancher {plancher:2d} bits"
            )


def main() -> None:
    parseur = argparse.ArgumentParser(description=__doc__)
    parseur.add_argument("--set", default=None, help="restreindre à une extension")
    parseur.add_argument("--size", type=int, default=16)
    parseur.add_argument("--photo", default=None, help="situer l'illustration dedans")
    parseur.add_argument("--carte", default="Take Up the Shield")
    arguments = parseur.parse_args()

    if arguments.photo:
        sur_photo(arguments.photo, arguments.carte)
        return

    portee = f" set:{arguments.set}" if arguments.set else ""
    sans_bord = mesurer(
        f"border:borderless -is:token lang:en{portee}",
        arguments.size,
        "sans bordure",
    )
    med_sans = resumer("sans bordure", sans_bord)

    # **Le témoin compte autant que la mesure.** Une fenêtre mesurée sur les
    # cartes ordinaires doit retomber sur le gabarit `modern` déjà en place
    # (0,080 / 0,120 / 0,920 / 0,550) ; si elle n'y retombe pas, c'est la méthode
    # qui est fausse, et non le gabarit qui manque.
    ordinaires = mesurer(
        f"border:black frame:2015 -is:token lang:en{portee}",
        max(6, arguments.size // 2),
        "cadre ordinaire (témoin)",
    )
    med_ord = resumer("cadre ordinaire (témoin)", ordinaires)

    if med_sans and med_ord:
        print("\ngabarit modern en place : left 0.080  top 0.120  right 0.920  bottom 0.550")
        print("le témoin doit s'en approcher ; l'écart entre les deux fenêtres")
        print("dit ce que le gabarit manquant vaut.")


if __name__ == "__main__":
    main()
