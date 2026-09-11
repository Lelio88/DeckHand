"""Le versement des dos : ce qui est accepté, ce qui est refusé, et pourquoi.

**Ce que ces tests protègent.** Pas le versement lui-même — il parle à Supabase
et se vérifie en le jouant. Ils tiennent trois choses qu'une retouche casse sans
bruit : que la table des sources reste **l'accord écrit** et rien d'autre (un
jeu sans base n'y entre pas, et chaque entrée cite la sienne), que le contrôle
du fichier attrape le dos d'un autre jeu — l'erreur qui ne se voit qu'à l'écran —,
et que la vérification CORS exige bien l'en-tête, pas seulement un 200.
"""

from __future__ import annotations

import io

import httpx
import pytest
from PIL import Image

from app.ingestion.card_back_upload import (
    ASPECT_TOLERANCE,
    OVERLAY_ORIGIN,
    SOURCES,
    _parse,
    check,
    verify_cors,
)
from app.vision.card_geometry import card_aspect_for


def jpeg(width: int, height: int, fmt: str = "JPEG") -> bytes:
    buffer = io.BytesIO()
    Image.new("RGB", (width, height), (40, 30, 90)).save(buffer, fmt)
    return buffer.getvalue()


def test_chaque_source_cite_ce_qui_autorise_la_copie():
    """**La table est l'accord.** Une entrée sans base écrite serait un dos
    réhébergé sur rien — exactement ce que §IV.10 interdit."""
    for game, source in SOURCES.items():
        assert source.basis.strip(), game
        assert source.url is None or source.url.startswith("https://"), game


def test_seuls_magic_et_yugioh_ont_une_base_ecrite():
    """Les six autres n'ont pas de dos publié par une source du projet :
    vérifié source par source, et en inventer un serait au mieux un 404."""
    assert set(SOURCES) == {"magic", "yugioh"}


@pytest.mark.parametrize(
    ("game", "taille"),
    [("yugioh", (428, 614)), ("magic", (488, 680))],
)
def test_le_dos_publie_passe_le_controle_de_son_jeu(game, taille):
    """Les dimensions réelles des deux fichiers publiés, mesurées le
    2026-09-11. Si le seuil se resserre au point de les refuser, c'est le
    seuil qui a tort."""
    assert check(jpeg(*taille), game) is None


@pytest.mark.parametrize(
    ("game", "taille"),
    [("yugioh", (488, 680)), ("magic", (428, 614))],
)
def test_le_dos_d_un_autre_jeu_est_refuse(game, taille):
    """**L'erreur que rien d'autre n'attrape.** Un dos Magic versé sous
    `yugioh/` se charge, se peint, et ne se voit qu'à l'écran — sur un direct.
    Les deux écarts, 0,019 et 0,032, sont ceux qui règlent le seuil."""
    raison = check(jpeg(*taille), game)

    assert raison is not None
    assert "autre jeu" in raison


def test_le_seuil_separe_bien_les_deux_dos():
    """Le seuil est réglé sur quatre nombres, pas au jugé : les deux dos
    dans leur jeu passent, échangés ils tombent. Ce test dit lesquels."""
    ecarts_bons = [abs(428 / 614 - card_aspect_for("yugioh")), abs(488 / 680 - card_aspect_for("magic"))]
    ecarts_echanges = [abs(488 / 680 - card_aspect_for("yugioh")), abs(428 / 614 - card_aspect_for("magic"))]

    assert max(ecarts_bons) < ASPECT_TOLERANCE < min(ecarts_echanges)


def test_un_png_ou_une_carte_couchee_sont_refuses():
    assert "JPEG" in check(jpeg(428, 614, "PNG"), "yugioh")
    assert "debout" in check(jpeg(614, 428), "yugioh")
    assert "illisible" in check(b"pas une image", "yugioh")


def test_la_verification_exige_l_en_tete_et_part_avec_l_origine_du_calque():
    """**Un 200 ne prouve rien.** `images.ygoprodeck.com` répond 200 et le
    calque ne voit rien : c'est l'en-tête qui compte, et il faut le demander
    avec l'`Origin` du calque — un hôte peut ne répondre qu'aux navigateurs."""
    origines: list[str | None] = []

    def repond(request: httpx.Request) -> httpx.Response:
        origines.append(request.headers.get("Origin"))
        if request.url.host == "sans-cors":
            return httpx.Response(200, content=b"\xff\xd8")
        return httpx.Response(
            200, content=b"\xff\xd8", headers={"Access-Control-Allow-Origin": "*"}
        )

    with httpx.Client(transport=httpx.MockTransport(repond)) as client:
        assert verify_cors(client, "https://sans-cors/back.jpg") is not None
        assert verify_cors(client, "https://avec-cors/back.jpg") is None

    assert origines == [OVERLAY_ORIGIN, OVERLAY_ORIGIN]


def test_la_ligne_de_commande_separe_les_jeux_du_fichier():
    assert _parse([]) == ([], None)
    assert _parse(["yugioh"]) == (["yugioh"], None)
    games, file = _parse(["wankul", "--file", "dos.jpg"])
    assert games == ["wankul"]
    assert file is not None and file.name == "dos.jpg"
