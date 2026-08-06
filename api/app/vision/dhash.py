"""Empreinte perceptuelle d'illustration — *difference hash*.

**Pourquoi dHash et non pHash.** L'algorithme devra être réimplémenté à
l'identique en Dart, puisque la reconnaissance s'exécute embarquée dans l'app.
dHash tient en une vingtaine de lignes sans transformée ni dépendance
numérique ; pHash exigerait une DCT en Dart, pour un gain de robustesse dont
rien ne prouve qu'il soit nécessaire ici. Si la reconnaissance s'avère
insuffisante en conditions réelles, c'est ce module — et son jumeau Dart —
qu'il faudra faire évoluer, pas l'architecture.

**Comment il fonctionne.** L'image est réduite en niveaux de gris à 9×8
pixels, puis chaque pixel est comparé à son voisin de droite : 8 comparaisons
par ligne, 8 lignes, soit 64 bits. Comparer des voisins plutôt que des valeurs
absolues rend l'empreinte insensible à un changement d'éclairage global — ce
qui compte, quand la référence est un scan officiel et la requête une photo
prise sur une table de cuisine.

**Pourquoi 64 bits et non davantage — mesuré, pas supposé.** Une empreinte de
256 bits (grille 16×16) a été comparée à celle de 64 bits sur les mêmes
illustrations, dégradées comme le ferait une photo médiocre. Elle s'est révélée
**moins fiable** : rapport de séparation médian de 1,9× contre 3,5× pour 64
bits. L'explication tient à ce que mesure chaque bit — une grille plus fine
capture des détails que le flou et la compression détruisent en premier, si bien
que la dégradation touche proportionnellement plus de bits. Augmenter la
résolution de l'empreinte est donc contre-productif ici ; inutile de retenter.

Mesures de référence (échantillon réel, illustrations Scryfall) :

| | 64 bits | 256 bits |
|---|---|---|
| distance au plus proche voisin (médiane) | 21 | 104 |
| distance après forte dégradation | 3–12 | 31–72 |
| rapport de séparation (médiane) | **3,5×** | 1,9× |

Deux illustrations sont considérées comme la même en deçà d'une distance de
Hamming de quelques bits ; le seuil exact se règle sur des mesures réelles,
pas a priori.
"""

from __future__ import annotations

from PIL import Image

# Côté de l'empreinte. 8 donne 8×8 = 64 bits.
HASH_SIZE = 8
HASH_BITS = HASH_SIZE * HASH_SIZE


def dhash(image: Image.Image, size: int = HASH_SIZE) -> int:
    """Calcule l'empreinte d'une image, sous forme d'entier non signé.

    L'image est redimensionnée à `(size + 1) × size` : la colonne
    supplémentaire fournit le voisin de droite du dernier pixel de chaque ligne.
    """
    grey = image.convert("L").resize((size + 1, size), Image.Resampling.LANCZOS)
    pixels = grey.load()

    bits = 0
    for y in range(size):
        for x in range(size):
            bits <<= 1
            if pixels[x, y] > pixels[x + 1, y]:
                bits |= 1
    return bits


def hamming_distance(a: int, b: int) -> int:
    """Nombre de bits qui diffèrent entre deux empreintes."""
    return (a ^ b).bit_count()


def to_signed_64(value: int) -> int:
    """Replie une valeur 64 bits non signée dans l'intervalle d'un `bigint`.

    Postgres n'a pas d'entier 64 bits non signé. La conversion est réversible :
    ajouter 2^64 à une valeur négative restitue l'empreinte d'origine.
    """
    return value - 2**64 if value >= 2**63 else value


def from_signed_64(value: int) -> int:
    """Opération inverse de `to_signed_64`."""
    return value + 2**64 if value < 0 else value
