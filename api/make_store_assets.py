"""Génère l'icône et la bannière de la fiche Play Store.

**Pourquoi un script plutôt que deux fichiers déposés.** Les images de fiche se
refont : un changement de teinte, un nom qui s'allonge, une exigence de Play qui
bouge. Un script les régénère à l'identique ; deux PNG figés obligent à rouvrir
un éditeur et à retrouver les valeurs de départ.

**L'identité vient de l'application, pas d'une palette inventée.** Fond sombre
chaud et accents dorés sont ceux des écrans — relevés sur les captures du
téléphone, pas choisis ici.

**Le motif est un éventail de cartes**, ce que le nom dit déjà : une main de
cartes. Trois suffisent à le faire lire à 48 pixels, taille à laquelle l'icône
sera vue le plus souvent ; au-delà de trois, elles se confondent.

Le dessin se fait à quadruple résolution puis se réduit : PIL ne lisse pas les
bords des polygones, et un rectangle incliné sans cette précaution rend un
escalier bien visible.

Usage :
    cd api && .venv/Scripts/python make_store_assets.py
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

SORTIE = Path(__file__).resolve().parent.parent / "app" / "store"

#: Relevés sur les captures de l'application.
FOND = (18, 16, 26)
FOND_HAUT = (30, 26, 40)
CREME = (237, 227, 200)
OR = (201, 169, 97)
OR_SOMBRE = (138, 115, 67)

#: Facteur de suréchantillonnage. Quatre suffit ; au-delà, la réduction ne gagne
#: plus rien de visible et le dessin devient lent.
ECHELLE = 4


def polices() -> tuple[ImageFont.FreeTypeFont, ImageFont.FreeTypeFont]:
    """Une police du système, ou celle de PIL en dernier recours."""
    candidates = [
        r"C:\Windows\Fonts\segoeuib.ttf",
        r"C:\Windows\Fonts\arialbd.ttf",
        r"C:\Windows\Fonts\calibrib.ttf",
    ]
    legere = [
        r"C:\Windows\Fonts\segoeui.ttf",
        r"C:\Windows\Fonts\arial.ttf",
        r"C:\Windows\Fonts\calibri.ttf",
    ]

    def premiere(chemins: list[str], taille: int):
        for chemin in chemins:
            if Path(chemin).exists():
                return ImageFont.truetype(chemin, taille)
        return ImageFont.load_default()

    return premiere(candidates, 132), premiere(legere, 46)


def fond_degrade(largeur: int, hauteur: int) -> Image.Image:
    """Fond sombre, très légèrement plus clair en haut.

    Un aplat parfait paraît mort à grande taille ; le dégradé se voit à peine
    mais donne de la profondeur derrière les cartes.
    """
    image = Image.new("RGB", (largeur, hauteur), FOND)
    dessin = ImageDraw.Draw(image)
    for y in range(hauteur):
        part = y / hauteur
        couleur = tuple(
            round(FOND_HAUT[i] + (FOND[i] - FOND_HAUT[i]) * part) for i in range(3)
        )
        dessin.line([(0, y), (largeur, y)], fill=couleur)
    return image


def carte(
    dessin: ImageDraw.ImageDraw,
    centre: tuple[float, float],
    taille: tuple[float, float],
    angle: float,
    remplissage: tuple[int, int, int],
    bord: tuple[int, int, int],
) -> None:
    """Une carte : rectangle incliné, tracé comme un polygone.

    `rounded_rectangle` ne sait pas tourner ; on calcule donc les quatre coins à
    la main. Le coin arrondi disparaît, ce qui ne se voit pas à cette échelle et
    évite de composer quatre images tournées.
    """
    import math

    cx, cy = centre
    demi_l, demi_h = taille[0] / 2, taille[1] / 2
    radians = math.radians(angle)
    cos, sin = math.cos(radians), math.sin(radians)
    coins = []
    for dx, dy in ((-demi_l, -demi_h), (demi_l, -demi_h), (demi_l, demi_h), (-demi_l, demi_h)):
        coins.append((cx + dx * cos - dy * sin, cy + dx * sin + dy * cos))
    dessin.polygon(coins, fill=remplissage, outline=bord, width=max(1, ECHELLE))


#: Fenêtre d'illustration du cadre Magic moderne, en proportions de la carte.
#:
#: Reprise telle quelle de `CardFrame.modern` : c'est la zone que la
#: reconnaissance découpe pour calculer une empreinte. La dessiner fait lire le
#: rectangle du dessus comme une **carte** et non comme une page blanche, et
#: c'est le geste central du produit qui se trouve ainsi cité.
FENETRE = (0.080, 0.120, 0.920, 0.550)


def eventail(dessin: ImageDraw.ImageDraw, centre: tuple[float, float], hauteur: float) -> None:
    """Trois cartes en éventail, la plus claire devant.

    L'ordre de tracé fait la profondeur : les latérales d'abord, la centrale
    par-dessus. Les proportions sont celles d'une vraie carte (63 x 88 mm).
    """
    largeur = hauteur * 63 / 88
    cx, cy = centre
    carte(dessin, (cx - hauteur * 0.32, cy + hauteur * 0.05), (largeur, hauteur), -22, OR_SOMBRE, FOND)
    carte(dessin, (cx + hauteur * 0.32, cy + hauteur * 0.05), (largeur, hauteur), 22, OR, FOND)

    haut_carte = cy - hauteur * 0.05
    carte(dessin, (cx, haut_carte), (largeur, hauteur), 0, CREME, FOND)

    # La fenêtre, sur la seule carte droite : l'inclinaison des deux autres
    # rendrait le détail illisible à 48 pixels, où l'icône sera surtout vue.
    gauche = cx - largeur / 2 + largeur * FENETRE[0]
    droite = cx - largeur / 2 + largeur * FENETRE[2]
    sommet = haut_carte - hauteur / 2 + hauteur * FENETRE[1]
    base = haut_carte - hauteur / 2 + hauteur * FENETRE[3]
    dessin.rectangle([gauche, sommet, droite, base], fill=OR_SOMBRE)

    # Deux traits sous la fenêtre : le pavé de texte, suggéré et non écrit.
    for i, part in enumerate((0.64, 0.72)):
        y = haut_carte - hauteur / 2 + hauteur * part
        fin = droite if i == 0 else droite - largeur * 0.22
        dessin.rectangle(
            [gauche, y, fin, y + hauteur * 0.028], fill=(196, 186, 162)
        )


def dessiner_icone(cote_final: int) -> Image.Image:
    """L'icône, dessinée à quadruple résolution puis réduite à [cote_final].

    Redessiner à chaque taille plutôt que réduire le 512 : à 48 pixels, une
    réduction par huit de l'image finale empâte les bords des cartes, là où le
    dessin refait garde ses arêtes.
    """
    cote = cote_final * ECHELLE
    image = fond_degrade(cote, cote)
    dessin = ImageDraw.Draw(image)
    eventail(dessin, (cote / 2, cote / 2), cote * 0.42)
    return image.resize((cote_final, cote_final), Image.LANCZOS)


def icone() -> Path:
    """512 x 512, motif centré à 62 % — Play arrondit les coins par-dessus."""
    chemin = SORTIE / "icon-512.png"
    dessiner_icone(512).save(chemin)
    return chemin


#: Densités Android et le côté attendu par chacune, en pixels.
#:
#: Le lanceur ne lit pas l'icône de la fiche Play : celle-ci reste sur le serveur
#: de Google. Sans ces fichiers, l'application porte le logo Flutter du gabarit
#: de départ — ce qu'un `flutter analyze` ne signale pas et qu'aucun test ne
#: voit, mais que tout testeur a sous les yeux au premier lancement.
DENSITES = {
    "mdpi": 48,
    "hdpi": 72,
    "xhdpi": 96,
    "xxhdpi": 144,
    "xxxhdpi": 192,
}


def icones_lanceur() -> list[Path]:
    """Remplace `ic_launcher.png` dans chaque `mipmap-*` du projet Android."""
    res = (
        Path(__file__).resolve().parent.parent
        / "app" / "android" / "app" / "src" / "main" / "res"
    )
    ecrits: list[Path] = []
    for densite, cote in DENSITES.items():
        dossier = res / f"mipmap-{densite}"
        if not dossier.exists():
            continue
        chemin = dossier / "ic_launcher.png"
        dessiner_icone(cote).save(chemin)
        ecrits.append(chemin)
    return ecrits


def police_ajustee(chemin: str | None, texte: str, largeur_max: float, plafond: int):
    """La plus grande taille qui fait tenir `texte` dans `largeur_max`.

    **Mesurer plutôt que supposer.** La première version fixait les tailles à la
    main : « DeckHand » débordait de moitié hors du cadre, et le défaut ne s'est
    vu qu'en regardant l'image. Une largeur dépend de la police installée, qui
    n'est pas la même d'un poste à l'autre — la calculer est le seul moyen de
    produire la même bannière partout.
    """
    if chemin is None:
        return ImageFont.load_default()
    taille = plafond
    while taille > 8:
        police = ImageFont.truetype(chemin, taille)
        if police.getlength(texte) <= largeur_max:
            return police
        taille -= max(1, taille // 40)
    return ImageFont.truetype(chemin, 8)


def banniere() -> Path:
    """1024 x 500 : l'éventail à gauche, le nom et la promesse à droite."""
    largeur, hauteur = 1024 * ECHELLE, 500 * ECHELLE
    image = fond_degrade(largeur, hauteur)
    dessin = ImageDraw.Draw(image)
    # 0,21 et non 0,17 : plus à gauche, la carte inclinée se faisait couper net
    # par le bord, ce qui se lit comme un cadrage raté plutôt que comme un choix.
    eventail(dessin, (largeur * 0.21, hauteur * 0.5), hauteur * 0.44)

    grasse, legere = polices()
    chemin_gras = getattr(grasse, "path", None)
    chemin_leger = getattr(legere, "path", None)

    x = largeur * 0.36
    dispo = largeur * 0.96 - x

    titre = police_ajustee(chemin_gras, "DeckHand", dispo, int(hauteur * 0.30))
    ligne1 = "Vos cartes réelles, rangées et jouables"
    ligne2 = "Collection · valeur · decks constructibles"
    sous = police_ajustee(chemin_leger, ligne1, dispo, int(hauteur * 0.10))
    sous2 = police_ajustee(chemin_leger, ligne2, dispo, int(hauteur * 0.09))

    dessin.text((x, hauteur * 0.36), "DeckHand", font=titre, fill=CREME, anchor="lm")
    dessin.text((x, hauteur * 0.58), ligne1, font=sous, fill=OR, anchor="lm")
    dessin.text((x, hauteur * 0.71), ligne2, font=sous2, fill=(150, 142, 128), anchor="lm")

    image = image.resize((1024, 500), Image.LANCZOS)
    chemin = SORTIE / "feature-1024x500.png"
    image.save(chemin)
    return chemin


if __name__ == "__main__":
    SORTIE.mkdir(parents=True, exist_ok=True)
    for chemin in (icone(), banniere()):
        taille = Image.open(chemin).size
        print(f"{chemin.name:26} {taille[0]} x {taille[1]}")
    for chemin in icones_lanceur():
        taille = Image.open(chemin).size
        print(f"{chemin.parent.name + '/' + chemin.name:26} "
              f"{taille[0]} x {taille[1]}")
