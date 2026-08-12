"""Tests des proportions de carte, et de leur parité avec le Dart.

**Pourquoi relire le fichier Dart plutôt que recopier ses valeurs.** Les deux
implémentations doivent rendre les mêmes coins : l'index est calculé côté
Python, la reconnaissance s'exécute côté Dart, et deux rapports qui
divergeraient produiraient des empreintes incomparables. Cette divergence ne se
signale pas — elle fait simplement échouer le scan, ce qui conduit à accuser
l'algorithme. Un test qui recopierait les valeurs à la main ne verrouillerait
rien : il divergerait en même temps que le module qu'il surveille.
"""

from __future__ import annotations

import ast
import re
from pathlib import Path

from app.vision.card_geometry import (
    CARD_ASPECTS,
    DEFAULT_CARD_ASPECT,
    card_aspect_for,
)

DART = (
    Path(__file__).resolve().parents[2]
    / "app"
    / "lib"
    / "src"
    / "features"
    / "scan"
    / "domain"
    / "card_geometry.dart"
)


def _number(node: ast.expr) -> float:
    """Évalue une expression arithmétique de nombres, et rien d'autre.

    Les valeurs sont écrites `63 / 88` des deux côtés — la division dit le
    carton dont elles viennent, là où `0.7159...` ne dirait plus rien. Il faut
    donc évaluer, mais sans ouvrir la porte à autre chose qu'un calcul.
    """
    if isinstance(node, ast.Constant) and isinstance(node.value, (int, float)):
        return float(node.value)
    if isinstance(node, ast.BinOp) and isinstance(
        node.op, (ast.Add, ast.Sub, ast.Mult, ast.Div)
    ):
        left, right = _number(node.left), _number(node.right)
        return {
            ast.Add: lambda: left + right,
            ast.Sub: lambda: left - right,
            ast.Mult: lambda: left * right,
            ast.Div: lambda: left / right,
        }[type(node.op)]()
    raise AssertionError(f"expression inattendue dans le Dart : {ast.dump(node)}")


def dart_aspects() -> dict[str, float]:
    """La table `cardAspects` du fichier Dart."""
    source = DART.read_text(encoding="utf-8")
    body = re.search(r"cardAspects\s*=\s*\{(.*?)\n\};", source, re.S)
    assert body, "table cardAspects introuvable dans card_geometry.dart"

    entries: dict[str, float] = {}
    for game, expression in re.findall(r"'([^']+)':\s*([^,\n]+),", body.group(1)):
        entries[game] = _number(ast.parse(expression.strip(), mode="eval").body)
    return entries


def test_les_deux_tables_couvrent_les_memes_jeux():
    assert set(dart_aspects()) == set(CARD_ASPECTS)


def test_les_deux_tables_donnent_les_memes_proportions():
    for game, aspect in dart_aspects().items():
        assert CARD_ASPECTS[game] == aspect


def test_le_repli_est_le_meme_des_deux_cotes():
    source = DART.read_text(encoding="utf-8")
    match = re.search(r"defaultCardAspect\s*=\s*([^;]+);", source)
    assert match, "defaultCardAspect introuvable dans card_geometry.dart"
    assert DEFAULT_CARD_ASPECT == _number(
        ast.parse(match.group(1).strip(), mode="eval").body
    )


def test_un_jeu_inconnu_retombe_sur_le_repli():
    # Refuser de scanner serait pire que scanner de travers : le repli garde la
    # reconnaissance en marche. C'est la parité des tables, ci-dessus, qui
    # empêche d'y arriver par accident.
    assert card_aspect_for("un-jeu-qui-n-existe-pas") == DEFAULT_CARD_ASPECT


def test_les_deux_jeux_couverts_impriment_sur_le_meme_carton():
    # Fait établi, et c'est précisément ce qui a permis à la constante de rester
    # en dur si longtemps sans que rien ne casse.
    assert card_aspect_for("magic") == card_aspect_for("riftbound")
    assert card_aspect_for("magic") == 63 / 88
