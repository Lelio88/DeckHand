"""Le repli sur le trait d'union, joué sans réseau (#21).

**Ce que ces tests protègent.** D'abord qu'un second essai parte quand le
premier n'a rien rendu — c'est tout l'objet du repli. Ensuite, et surtout,
qu'il **ne parte pas** autrement : chaque appel de plus est une requête de plus
sur un chat en direct, et un repli qui poserait deux fois la même question ne
coûterait que du débit.

Le défaut corrigé est mesuré (`app.measure.nom_trait_union`) : sur un **nom
complet** mal saisi, la similarité trigramme absorbe tout — 2 111 noms Magic
éprouvés, zéro perdu. C'est sur un **fragment** que le trait d'union décide, et
il y coûte 21 cartes en Magic, 32 en Yu-Gi-Oh.
"""

from __future__ import annotations

import json

import httpx

from app.twitch.locator import Locator, variante_trait_union


def une_case() -> dict[str, object]:
    return {
        "name": "Ka-Zar of the Savage Land",
        "matched_name": "Ka-Zar de la Terre sauvage",
        "score": 1.0,
        "set_code": "msh",
        "set_name": "Marvel Super Heroes",
        "collector_number": "185",
        "page": 3,
        "slot": 4,
        "copies": 1,
        "has_foil": False,
    }


class TestVariante:
    def test_deux_mots_deviennent_un_mot_a_trait_d_union(self) -> None:
        """Le cas mesuré : « ka zar » pour *Ka-Zar*."""
        assert variante_trait_union("ka zar") == "ka-zar"

    def test_le_sens_inverse_est_essaye_aussi(self) -> None:
        assert variante_trait_union("ka-zar") == "ka zar"

    def test_un_mot_seul_n_a_rien_a_echanger(self) -> None:
        """**Rendre `None` plutôt que la même chaîne.** Un second appel
        identique poserait la même question et coûterait une requête pour un
        résultat déjà connu."""
        assert variante_trait_union("kazar") is None

    def test_une_saisie_vide_ou_blanche_ne_produit_rien(self) -> None:
        assert variante_trait_union("") is None
        assert variante_trait_union("   ") is None

    def test_le_trait_d_union_prime_quand_les_deux_sont_presents(self) -> None:
        assert variante_trait_union("mage il-vec") == "mage il vec"


class TestRepli:
    def _locator(self) -> Locator:
        return Locator(supabase_url="https://x", anon_key="k", handle="lelio")

    def test_un_second_essai_part_quand_le_premier_ne_rend_rien(self) -> None:
        vues: list[str] = []

        def repondre(request: httpx.Request) -> httpx.Response:
            query = json.loads(request.content)["p_query"]
            vues.append(query)
            trouve = [une_case()] if query == "ka-zar" else []
            return httpx.Response(200, json=trouve)

        with httpx.Client(transport=httpx.MockTransport(repondre)) as client:
            cases = self._locator().locate(client, "ka zar")

        assert vues == ["ka zar", "ka-zar"]
        assert len(cases) == 1

    def test_aucun_second_essai_quand_le_premier_a_trouve(self) -> None:
        """**Le repli ne coûte qu'un échec.** Sur une recherche qui aboutit, il
        doublerait le trafic du bot sans rien apporter."""
        vues: list[str] = []

        def repondre(request: httpx.Request) -> httpx.Response:
            vues.append(json.loads(request.content)["p_query"])
            return httpx.Response(200, json=[une_case()])

        with httpx.Client(transport=httpx.MockTransport(repondre)) as client:
            assert self._locator().locate(client, "ka zar")

        assert vues == ["ka zar"]

    def test_aucun_second_essai_sans_variante_possible(self) -> None:
        vues: list[str] = []

        def repondre(request: httpx.Request) -> httpx.Response:
            vues.append(json.loads(request.content)["p_query"])
            return httpx.Response(200, json=[])

        with httpx.Client(transport=httpx.MockTransport(repondre)) as client:
            assert self._locator().locate(client, "kazar") == []

        assert vues == ["kazar"]

    def test_un_second_essai_infructueux_se_tait_comme_le_premier(self) -> None:
        with httpx.Client(
            transport=httpx.MockTransport(lambda _r: httpx.Response(200, json=[]))
        ) as client:
            assert self._locator().locate(client, "ka zar") == []

    def test_une_panne_reseau_reste_muette_malgre_le_repli(self) -> None:
        """**Deux essais, toujours zéro trace au chat.** Le repli ne change rien
        au contrat : une panne ne dit rien de plus qu'une carte absente."""
        appels: list[int] = []

        def tomber(_request: httpx.Request) -> httpx.Response:
            appels.append(1)
            return httpx.Response(500)

        with httpx.Client(transport=httpx.MockTransport(tomber)) as client:
            assert self._locator().locate(client, "ka zar") == []

        # Le repli part aussi sur une panne : `_interroger` rend une liste vide
        # dans les deux cas, à dessein — voir l'en-tête de `locator`.
        assert len(appels) == 2
