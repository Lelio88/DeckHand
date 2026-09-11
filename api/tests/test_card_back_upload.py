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
import tempfile
from pathlib import Path

import httpx
import pytest
from PIL import Image

from app.config import SupabaseConfig
from app.ingestion.card_back_upload import (
    ASPECT_TOLERANCE,
    OVERLAY_ORIGIN,
    SOURCES,
    _parse,
    check,
    run,
    verify_cors,
)
from app.vision.card_geometry import card_aspect_for


def jpeg(width: int, height: int, fmt: str = "JPEG") -> bytes:
    buffer = io.BytesIO()
    Image.new("RGB", (width, height), (40, 30, 90)).save(buffer, fmt)
    return buffer.getvalue()


def _config() -> SupabaseConfig:
    return SupabaseConfig(
        url="https://abc.supabase.co",
        anon_key="anon",
        service_key="service",
        db_url="postgresql://…",
    )


def test_chaque_source_cite_ce_qui_autorise_la_copie():
    """**La table est l'accord.** Une entrée sans base écrite serait un dos
    réhébergé sur rien — exactement ce que §IV.10 interdit."""
    for game, source in SOURCES.items():
        assert source.basis.strip(), game
        assert source.url is None or source.url.startswith("https://"), game


def test_la_table_dit_exactement_qui_a_le_droit():
    """Une entrée ajoutée par habitude passerait la copie sans base écrite."""
    assert set(SOURCES) == {"magic", "yugioh", "wankul"}
    assert "riftbound" not in SOURCES


def test_wankul_a_le_droit_mais_pas_de_fichier():
    """`url=None` suffit à l'écarter d'une course sans argument, qui ne va
    chercher que ce qui est publié."""
    assert SOURCES["wankul"].url is None
    assert "LINK DIGITAL SPIRIT" in SOURCES["wankul"].basis


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


def test_un_dos_remis_hors_ligne_se_verse_sans_appeler_la_source():
    """Éprouvé avant qu'un dos hors ligne n'arrive, non le jour où il arrive :
    `--file` lit le disque, verse, relit — et ne frappe aucune source."""
    appels: list[tuple[str, str]] = []

    def repond(request: httpx.Request) -> httpx.Response:
        appels.append((request.method, request.url.path))
        if request.method == "POST":
            return httpx.Response(200, json={"Key": "card-art/wankul/back.jpg"})
        return httpx.Response(
            200, content=b"\xff\xd8", headers={"Access-Control-Allow-Origin": "*"}
        )

    fichier = Path(tempfile.mkdtemp()) / "dos-wankul.jpg"
    fichier.write_bytes(jpeg(430, 600))
    config = SupabaseConfig(
        url="https://abc.supabase.co",
        anon_key="anon",
        service_key="service",
        db_url="postgresql://…",
    )

    with httpx.Client(transport=httpx.MockTransport(repond)) as client:
        code = run(["wankul"], file=fichier, config=config, client=client)

    assert code == 0
    assert appels == [
        ("POST", "/storage/v1/object/card-art/wankul/back.jpg"),
        ("GET", "/storage/v1/object/public/card-art/wankul/back.jpg"),
    ]


def test_sans_fichier_wankul_echoue_au_lieu_de_verser_n_importe_quoi():
    """Un jeu sans dos publié et sans `--file` n'a rien à verser. L'échec est
    la bonne réponse : il dit quoi faire, et n'invente pas d'URL."""
    config = SupabaseConfig(
        url="https://abc.supabase.co",
        anon_key="anon",
        service_key="service",
        db_url="postgresql://…",
    )

    def repond(request: httpx.Request) -> httpx.Response:  # pragma: no cover
        raise AssertionError(f"aucun appel attendu, reçu {request.url}")

    with httpx.Client(transport=httpx.MockTransport(repond)) as client:
        code = run(["wankul"], config=config, client=client)

    assert code == 1


def test_un_jeu_sans_base_ecrite_est_refuse_avant_tout_appel():
    """**La table est l'accord**, et ce refus en est la serrure : un fichier en
    main ne suffit pas, il faut l'accord inscrit."""
    with pytest.raises(SystemExit) as sortie:
        run(["riftbound"])

    assert "aucune base écrite pour riftbound" in str(sortie.value)


def test_la_ligne_de_commande_separe_les_jeux_du_fichier():
    assert _parse([]) == ([], None, False)
    assert _parse(["yugioh"]) == (["yugioh"], None, False)
    games, file, scan = _parse(["wankul", "--file", "dos.jpg", "--scan"])
    assert games == ["wankul"]
    assert file is not None and file.name == "dos.jpg"
    assert scan is True


def test_un_scan_verse_un_jeu_que_la_table_n_autorise_pas():
    """**La porte qui ne copie personne.** Le fichier vient d'une carte
    possédée : rien n'est réhébergé, donc l'absence d'accord de source ne
    bloque pas. Lorcana n'est pas dans la table, et se verse quand même."""
    appels: list[tuple[str, str]] = []

    def repond(request: httpx.Request) -> httpx.Response:
        appels.append((request.method, request.url.path))
        if request.method == "POST":
            return httpx.Response(200, json={"Key": "card-art/lorcana/back.jpg"})
        return httpx.Response(
            200, content=b"\xff\xd8", headers={"Access-Control-Allow-Origin": "*"}
        )

    fichier = Path(tempfile.mkdtemp()) / "scan.jpg"
    fichier.write_bytes(jpeg(430, 600))

    with httpx.Client(transport=httpx.MockTransport(repond)) as client:
        code = run(["lorcana"], file=fichier, scan=True, config=_config(), client=client)

    assert code == 0
    assert "lorcana" not in SOURCES
    assert appels == [
        ("POST", "/storage/v1/object/card-art/lorcana/back.jpg"),
        ("GET", "/storage/v1/object/public/card-art/lorcana/back.jpg"),
    ]


def test_un_scan_de_travers_est_refuse_comme_les_autres():
    """Le contrôle reste entier : un scan couché se voit ici, pas sur un direct."""
    fichier = Path(tempfile.mkdtemp()) / "couche.jpg"
    fichier.write_bytes(jpeg(600, 430))

    def repond(request: httpx.Request) -> httpx.Response:  # pragma: no cover
        raise AssertionError(f"aucun versement attendu, reçu {request.url}")

    with httpx.Client(transport=httpx.MockTransport(repond)) as client:
        code = run(["lorcana"], file=fichier, scan=True, config=_config(), client=client)

    assert code == 1


def test_un_scan_exige_son_fichier_et_un_jeu_du_projet():
    with pytest.raises(SystemExit) as sortie:
        run(["lorcana"], scan=True)
    assert "--file" in str(sortie.value)

    with pytest.raises(SystemExit) as sortie:
        run(["lorcanaa"], file=Path("x.jpg"), scan=True)
    assert "jeu inconnu du projet" in str(sortie.value)
