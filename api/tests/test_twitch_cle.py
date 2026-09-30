"""La clé du calque : son rangement dans le coffre, et son usage par le bot.

**Ce que ces tests protègent.** D'abord que poser la clé ne réécrit rien d'autre
de `twitch.env` — le fichier porte aussi le jeton Twitch. Ensuite que le bot
écrive par les portes `bot_request_*`, clé comprise, et qu'il **n'écrive pas du
tout** sans clé : la base refuserait, et chaque appel voué à l'échec est une
requête de plus pendant un direct.
"""

from __future__ import annotations

import json

import httpx

from app.twitch.cle import avec_cle
from app.twitch.locator import Locator


class TestRangement:
    def test_la_cle_est_ajoutee_sans_toucher_au_reste(self) -> None:
        texte = "# jeton du bot\nTWITCH_TOKEN=oauth:abc\nDECKHAND_HANDLE=lelio\n"

        rendu = avec_cle(texte, "neuve")

        assert rendu == (
            "# jeton du bot\nTWITCH_TOKEN=oauth:abc\nDECKHAND_HANDLE=lelio\n"
            "DECKHAND_OVERLAY_KEY=neuve\n"
        )

    def test_une_cle_existante_est_remplacee_en_place(self) -> None:
        texte = "TWITCH_TOKEN=oauth:abc\nDECKHAND_OVERLAY_KEY=vieille\nDECKHAND_HANDLE=lelio\n"

        rendu = avec_cle(texte, "neuve")

        assert rendu == "TWITCH_TOKEN=oauth:abc\nDECKHAND_OVERLAY_KEY=neuve\nDECKHAND_HANDLE=lelio\n"
        assert "vieille" not in rendu


class TestEcriture:
    def _capturer(self) -> tuple[list[dict[str, object]], httpx.Client]:
        vus: list[dict[str, object]] = []

        def repondre(request: httpx.Request) -> httpx.Response:
            vus.append({"url": str(request.url), "corps": json.loads(request.content)})
            return httpx.Response(200, json=True)

        return vus, httpx.Client(transport=httpx.MockTransport(repondre))

    def test_la_designation_passe_par_la_porte_du_bot_avec_la_cle(self) -> None:
        vus, client = self._capturer()
        locator = Locator(supabase_url="https://x", anon_key="k", handle="lelio", overlay_key="cle")

        with client:
            accepte = locator.designate(client, "msh", "185", "alice")

        assert accepte is True
        assert vus[0]["url"] == "https://x/rest/v1/rpc/bot_request_spotlight"
        assert vus[0]["corps"]["p_key"] == "cle"
        assert vus[0]["corps"]["p_handle"] == "lelio"

    def test_page_et_tapis_passent_aussi_par_la_porte_du_bot(self) -> None:
        vus, client = self._capturer()
        locator = Locator(supabase_url="https://x", anon_key="k", handle="lelio", overlay_key="cle")

        with client:
            locator.designate_page(client, "msh", 2, "bob")
            locator.designate_strip(client, "msh", "185", "carol")

        assert [v["url"].rsplit("/", 1)[1] for v in vus] == [
            "bot_request_spotlight_page",
            "bot_request_spotlight_strip",
        ]
        assert all(v["corps"]["p_key"] == "cle" for v in vus)

    def test_sans_cle_aucune_requete_ne_part(self) -> None:
        vus, client = self._capturer()
        locator = Locator(supabase_url="https://x", anon_key="k", handle="lelio")

        with client:
            assert locator.designate(client, "msh", "185", "alice") is False
            assert locator.designate_page(client, "msh", 2, "bob") is False
            assert locator.designate_strip(client, "msh", "185", "carol") is False

        assert vus == []
