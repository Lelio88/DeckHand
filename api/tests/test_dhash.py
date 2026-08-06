"""Tests de l'empreinte perceptuelle.

L'algorithme doit résister à ce qu'une photo fait subir à une illustration —
changement de luminosité, redimensionnement, compression — tout en séparant
nettement deux illustrations distinctes.
"""

from PIL import Image, ImageEnhance

from app.vision.dhash import HASH_BITS, dhash, hamming_distance, to_signed_64


def gradient(width: int = 200, height: int = 200, shift: int = 0) -> Image.Image:
    """Image de test déterministe : un dégradé diagonal."""
    img = Image.new("RGB", (width, height))
    pixels = img.load()
    for x in range(width):
        for y in range(height):
            v = (x * 2 + y + shift) % 256
            pixels[x, y] = (v, (v * 3) % 256, (v * 7) % 256)
    return img


def blocks() -> Image.Image:
    """Image nettement différente du dégradé : des blocs contrastés."""
    img = Image.new("RGB", (200, 200), (10, 10, 10))
    pixels = img.load()
    for x in range(100, 200):
        for y in range(0, 100):
            pixels[x, y] = (240, 240, 240)
    return img


def test_hash_is_64_bits():
    assert HASH_BITS == 64
    assert 0 <= dhash(gradient()) < 2**64


def test_same_image_gives_same_hash():
    assert dhash(gradient()) == dhash(gradient())


def test_resizing_barely_changes_the_hash():
    """Une photo n'a jamais la résolution de l'illustration de référence."""
    original = gradient(400, 400)
    resized = original.resize((150, 150))
    assert hamming_distance(dhash(original), dhash(resized)) <= 6


def test_brightness_change_barely_changes_the_hash():
    """dhash compare des pixels voisins : un éclairage global le déplace peu."""
    original = gradient()
    brighter = ImageEnhance.Brightness(original).enhance(1.4)
    assert hamming_distance(dhash(original), dhash(brighter)) <= 6


def test_different_images_are_far_apart():
    assert hamming_distance(dhash(gradient()), dhash(blocks())) >= 16


def test_grayscale_conversion_is_applied():
    """Une image colorée et sa version en niveaux de gris se ressemblent."""
    original = gradient()
    grey = original.convert("L").convert("RGB")
    assert hamming_distance(dhash(original), dhash(grey)) <= 8


# --- hamming_distance -------------------------------------------------------


def test_hamming_distance_of_identical_values_is_zero():
    assert hamming_distance(0xDEADBEEF, 0xDEADBEEF) == 0


def test_hamming_distance_counts_differing_bits():
    assert hamming_distance(0b0000, 0b0111) == 3


# --- to_signed_64 -----------------------------------------------------------


def test_small_values_are_unchanged():
    assert to_signed_64(42) == 42


def test_values_above_the_signed_range_wrap_to_negative():
    """Postgres n'a pas de bigint non signé : il faut replier la valeur."""
    assert to_signed_64(2**64 - 1) == -1
    assert to_signed_64(2**63) == -(2**63)


def test_signed_conversion_is_reversible():
    original = 0xFFEEDDCCBBAA9988
    signed = to_signed_64(original)
    assert signed < 0
    assert signed + 2**64 == original
