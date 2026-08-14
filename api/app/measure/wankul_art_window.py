"""Banc : où se trouve l'illustration sur une carte Wankul.

**Deux mises en page, pas deux rotations.** La verticale porte une illustration
**encadrée** — un rectangle cerné de noir, surmonté d'un bandeau à icônes et
suivi d'un pavé de texte. L'horizontale porte son illustration **en plein
cadre**, les textes posés par-dessus. Mesurer l'une ne dit rien de l'autre, et
c'est pourquoi ce banc sépare les deux jeux d'images.

**La méthode est celle qui a rendu Pokémon** : ce qui survit à la moyenne, c'est
ce qui ne bouge pas — donc les traits du cadre. Le gradient de l'image moyenne
monte sur les arêtes communes à toutes les cartes et reste plat là où chacune
dessine autre chose. Wankul devrait s'y prêter mieux encore que Pokémon, dont le
cadre changeait de couleur avec le type : ici le cadre est noir sur toutes les
cartes.

**Deux mesures, et elles se contrôlent l'une l'autre.** Le gradient de la
moyenne donne un gabarit ; la mesure carte par carte donne sa **dispersion**. Un
gabarit sans dispersion serait une moyenne dont on ne saurait pas si elle décrit
quelque chose — c'est la leçon du gabarit de deck, où l'écart interquartile vaut
autant que la médiane.

**Le cadrage préalable n'est pas un détail.** Les rendus fournis portent des
marges transparentes de largeur variable, et deux d'entre eux (JPEG) n'en ont
aucune. Mesurer sans les retirer produirait des proportions fausses de la valeur
exacte de la marge — une erreur qui ne se voit qu'en comparant deux jeux.

Usage :
    cd api && .venv/Scripts/python -m app.measure.wankul_art_window <dossier>
    cd api && .venv/Scripts/python -m app.measure.wankul_art_window <dossier> --dump
"""

from __future__ import annotations

import sys
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image

#: Taille commune à laquelle les cartes sont ramenées avant d'être moyennées.
#: Assez grande pour que le trait du cadre reste net, assez petite pour que la
#: moyenne de quelques dizaines de cartes tienne en mémoire.
NORM = (600, 840)

#: Sous ce seuil d'opacité, un pixel est de la marge et non de la carte.
ALPHA_MIN = 16


@dataclass(frozen=True)
class Window:
    left: float
    top: float
    right: float
    bottom: float

    def __str__(self) -> str:
        return (f"({self.left:.4f}, {self.top:.4f}, "
                f"{self.right:.4f}, {self.bottom:.4f})")


def load_card(path: Path) -> np.ndarray | None:
    """L'image réduite à la carte elle-même, marges retirées.

    Les JPEG n'ont pas d'alpha : la carte y occupe déjà toute l'image, et il n'y
    a rien à retirer. Les traiter comme les PNG chercherait une transparence
    absente et rendrait un cadrage arbitraire.
    """
    img = Image.open(path)
    if img.mode in ("RGBA", "LA", "P"):
        img = img.convert("RGBA")
        a = np.asarray(img).astype(np.float32)
        opaque = a[:, :, 3] > ALPHA_MIN
        if not opaque.any():
            return None
        rows = np.where(opaque.any(axis=1))[0]
        cols = np.where(opaque.any(axis=0))[0]
        a = a[rows.min():rows.max() + 1, cols.min():cols.max() + 1, :3]
    else:
        a = np.asarray(img.convert("RGB")).astype(np.float32)
    return a


def normalized(card: np.ndarray) -> np.ndarray:
    """La carte ramenée à [NORM], en niveaux de gris."""
    img = Image.fromarray(card.astype(np.uint8)).resize(NORM, Image.LANCZOS)
    a = np.asarray(img).astype(np.float32)
    return a @ np.array([0.299, 0.587, 0.114], dtype=np.float32)


def window_from_gradient(mean: np.ndarray) -> Window:
    """Les arêtes du cadre, lues sur le gradient de l'image moyenne."""
    gy = np.abs(np.diff(mean, axis=0)).mean(axis=1)
    gx = np.abs(np.diff(mean, axis=1)).mean(axis=0)
    h, w = mean.shape

    def crete(profil: np.ndarray, debut: float, fin: float) -> int:
        """Position du plus fort gradient dans une plage."""
        a, b = int(len(profil) * debut), int(len(profil) * fin)
        return a + int(np.argmax(profil[a:b]))

    # Le haut de la fenêtre est sous le bandeau à icônes ; le bas est le trait
    # qui la sépare du pavé de texte. Les plages évitent les bords de carte,
    # dont le gradient est le plus fort de l'image et masquerait le reste.
    top = crete(gy, 0.03, 0.25)
    bottom = crete(gy, 0.55, 0.80)
    left = crete(gx, 0.02, 0.20)
    right = crete(gx, 0.80, 0.98)
    return Window(left / w, top / h, right / w, bottom / h)


def is_rotated_terrain(card: np.ndarray) -> bool:
    """Vrai si la carte est **couchée mais stockée debout**, donc à redresser.

    **Le rendu principal d'un Terrain est la carte tournée d'un quart de tour.**
    Son texte se lit de bas en haut, et son pavé n'est plus une bande
    horizontale mais une **colonne**. C'est ce basculement qui la distingue, et
    non sa taille : une verticale ordinaire et un Terrain tourné font tous deux
    435 x 600.

    Deux essais l'ont manqué avant celui-ci. Classer sur la clarté seule rangeait
    498 cartes en « pavé haut » — des ciels. Ajouter l'uniformité laissait encore
    « PRINCESSE » chez les couchées, ses cheveux blonds faisant un aplat clair au
    milieu. Ce qui tranche est l'**axe** du pavé, pas sa position.
    """
    g = normalized(card)
    h, w = g.shape

    def part_plate(profil_med, profil_ecart) -> float:
        return float(((profil_med > 170) & (profil_ecart < 45)).mean())

    lignes = part_plate(np.median(g[:, int(w * 0.2):int(w * 0.8)], axis=1),
                        g[:, int(w * 0.2):int(w * 0.8)].std(axis=1))
    colonnes = part_plate(np.median(g[int(h * 0.2):int(h * 0.8), :], axis=0),
                          g[int(h * 0.2):int(h * 0.8), :].std(axis=0))
    return colonnes > lignes


def per_card_bottom(card: np.ndarray) -> float | None:
    """Où commence le pavé de texte sur *cette* carte.

    Contrôle indépendant du gradient : le pavé est un aplat clair et peu
    saturé, l'illustration ne l'est jamais sur toute une ligne.
    """
    g = normalized(card)
    h, w = g.shape
    bande = g[:, int(w * 0.20):int(w * 0.80)]
    med = np.median(bande, axis=1)
    bas = [y for y in range(int(h * 0.5), h) if med[y] > 175]
    return min(bas) / h if bas else None


def redressee(card: np.ndarray) -> np.ndarray:
    """La carte couchée remise dans son sens de lecture.

    **Le lot contient les deux sens de rotation**, ce qu'une rotation uniforme
    ne pouvait pas rattraper : l'image moyenne de 150 Terrains montrait alors
    deux jeux de bandeaux, symétriques par rapport au centre — la moitié des
    cartes à l'endroit, l'autre à 180°.

    Le sens se décide donc carte par carte, sur un repère stable : les bandeaux
    de texte occupent la moitié **haute** d'un Terrain à l'endroit — mesuré sur
    « Road Trip », 0,097 à 0,446. S'ils tombent en bas, la carte est retournée.
    """
    droite = np.rot90(card, k=1)
    g = normalized(droite)
    h, w = g.shape
    bande = g[:, int(w * 0.15):int(w * 0.85)]
    med, ecart = np.median(bande, axis=1), bande.std(axis=1)
    plat = (med > 170) & (ecart < 45)
    haut = plat[: h // 2].sum()
    bas = plat[h // 2:].sum()
    return droite if haut >= bas else np.rot90(droite, k=2)


def mesure_terrains(cartes: list[np.ndarray]) -> None:
    """Le gabarit des cartes couchées, redressées puis moyennées."""
    pile = np.stack([normalized(redressee(c)) for c in cartes])
    mean = pile.mean(axis=0)
    h, w = mean.shape
    gy = np.abs(np.diff(mean, axis=0)).mean(axis=1)
    gx = np.abs(np.diff(mean, axis=1)).mean(axis=0)

    def cretes(profil, n=6):
        ordre = np.argsort(profil)[::-1]
        gardees: list[int] = []
        for i in ordre:
            if all(abs(i - j) > len(profil) * 0.04 for j in gardees):
                gardees.append(int(i))
            if len(gardees) == n:
                break
        return sorted(gardees)

    print("\n--- crêtes horizontales (y) ---")
    for y in cretes(gy):
        print(f"   {y / h:.4f}   force {gy[y]:6.1f}")
    print("--- crêtes verticales (x) ---")
    for x in cretes(gx):
        print(f"   {x / w:.4f}   force {gx[x]:6.1f}")

    sd = pile.std(axis=0)
    lignes = np.where(sd.mean(axis=1) > sd.mean() * 0.6)[0]
    colonnes = np.where(sd.mean(axis=0) > sd.mean() * 0.6)[0]
    print(f"\nzone où les cartes diffèrent : "
          f"y {lignes.min() / h:.4f}..{lignes.max() / h:.4f}   "
          f"x {colonnes.min() / w:.4f}..{colonnes.max() / w:.4f}")


def main() -> int:
    if len(sys.argv) < 2:
        print("usage : python -m app.measure.wankul_art_window <dossier> [--dump]",
              file=sys.stderr)
        return 64
    dossier = Path(sys.argv[1])
    fichiers = sorted(
        p for p in dossier.iterdir()
        if p.suffix.lower() in (".png", ".jpg", ".jpeg")
    )
    if not fichiers:
        print(f"aucune image dans {dossier}", file=sys.stderr)
        return 1

    cartes: list[tuple[Path, np.ndarray]] = []
    for p in fichiers:
        card = load_card(p)
        if card is None:
            print(f"  {p.name}: illisible, ignorée")
            continue
        h, w = card.shape[:2]
        # Ce banc ne mesure que les verticales : la maquette horizontale est
        # une autre mise en page, pas une rotation, et les moyenner ferait un
        # gabarit qui ne décrit aucune des deux.
        if w > h:
            print(f"  {p.name}: horizontale ({w}x{h}), écartée de ce banc")
            continue
        cartes.append((p, card))

    print(f"\ncartes verticales retenues : {len(cartes)}")
    print("\nnom                                     l x h    rapport")
    rapports = []
    for p, c in cartes:
        h, w = c.shape[:2]
        rapports.append(w / h)
        print(f"  {p.name[:36]:36} {w:4}x{h:<5} {w/h:.4f}")

    r = np.array(rapports)
    print(f"\nrapport : médiane {np.median(r):.4f}  min {r.min():.4f}  "
          f"max {r.max():.4f}   (63/88 = {63/88:.4f})")

    pile = np.stack([normalized(c) for _, c in cartes])
    mean = pile.mean(axis=0)
    fenetre = window_from_gradient(mean)
    print(f"\n=== fenêtre lue sur le gradient de la moyenne ===\n  {fenetre}")

    bas = [b for b in (per_card_bottom(c) for _, c in cartes) if b is not None]
    if bas:
        b = np.array(bas)
        print(f"\ncontrôle croisé — début du pavé de texte, carte par carte :")
        print(f"  médiane {np.median(b):.4f}   écart interquartile "
              f"{np.percentile(b, 75) - np.percentile(b, 25):.4f}"
              f"   min {b.min():.4f}  max {b.max():.4f}")
        ecart = abs(np.median(b) - fenetre.bottom)
        verdict = "concordent" if ecart < 0.02 else "DIVERGENT"
        print(f"  écart avec le gradient : {ecart:.4f} — les deux {verdict}")

    if "--dump" in sys.argv:
        sortie = dossier / "moyenne.png"
        Image.fromarray(mean.astype(np.uint8)).save(sortie)
        print(f"\nimage moyenne écrite : {sortie}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
