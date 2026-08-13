"""Tests de l'identité dérivée pour Riftbound.

**Ce qu'ils protègent.** La source n'expose aucun identifiant de carte ; on en
dérive un. Une règle trop lâche enregistre la même carte deux fois — la
collection la compte double et un deck qui cite l'une ne reconnaît pas l'autre.
Une règle trop stricte fusionne deux cartes différentes, ce qui est pire :
l'erreur devient indétectable, puisque plus rien ne les distingue.

Les figures reproduisent les cas mesurés sur le catalogue réel (1 451 entrées) et
consignés dans `oracle_uuid`.
"""

from __future__ import annotations

from typing import Any

from app.ingestion.riftcodex_ingest import (
    base_name,
    champion_names,
    display_name,
    oracle_uuid,
)


def carte(
    name: str,
    *,
    type_: str = "Unit",
    text: str | None = "",
    tags: list[str] | None = None,
) -> dict[str, Any]:
    return {
        "name": name,
        "classification": {"type": type_},
        "text": {"plain": text},
        "tags": tags or [],
    }


def identites(cards: list[dict[str, Any]]) -> set[str]:
    champions = champion_names(cards)
    return {str(oracle_uuid(c, champions)) for c in cards}


class TestVocabulaireDesChampions:
    def test_les_prefixes_fournissent_le_vocabulaire(self):
        cards = [carte("Ambessa - Matriarch of War"), carte("Lux, Crownguard")]
        assert champion_names(cards) == {"Ambessa", "Lux"}

    def test_un_prefixe_compose_en_fournit_deux(self):
        # « Yordle, Kennen - Heart of the Tempest » : une tribu, puis le champion.
        cards = [carte("Yordle, Kennen - Heart of the Tempest")]
        assert champion_names(cards) == {"Yordle", "Kennen"}

    def test_un_nom_sans_prefixe_n_apporte_rien(self):
        assert champion_names([carte("Altar of Blood")]) == frozenset()


class TestCeQueLIdentiteReunit:
    def test_le_prefixe_du_champion_present_ou_absent(self):
        # Mesuré : 7 groupes de Legend en VEN, dont Ambessa / Matriarch of War.
        cards = [
            carte("Ambessa - Matriarch of War", type_="Legend", tags=["Ambessa"]),
            carte("Matriarch of War", type_="Legend", tags=["Ambessa"]),
        ]
        assert len(identites(cards)) == 1

    def test_le_separateur_qui_change_d_extension(self):
        cards = [
            carte("Ahri - Inquisitive", tags=["Ahri", "Ionia"]),
            carte("Ahri, Inquisitive", tags=["Ahri"]),
        ]
        assert len(identites(cards)) == 1

    def test_le_texte_qui_perd_ses_rappels_de_regles(self):
        # L'extension VEN retire les parenthèses explicatives. C'est la cause la
        # plus fréquente : 63 groupes sur 87 tiennent au seul texte.
        cards = [
            carte(
                "Leona - Determined",
                tags=["Leona"],
                text="[Shield] (+1 while I'm a defender.)When I attack, stun.",
            ),
            carte("Leona - Determined", tags=["Leona"], text="[Shield]When I attack, stun."),
        ]
        assert len(identites(cards)) == 1

    def test_le_texte_vide_ecrit_de_deux_facons(self):
        # La source écrit tantôt '' tantôt '[NO TEXT]' pour la même Rune.
        cards = [
            carte("Body Rune", type_="Rune", text=""),
            carte("Body Rune", type_="Rune", text="[NO TEXT]"),
        ]
        assert len(identites(cards)) == 1

    def test_un_tag_ajoute_dans_une_extension_ne_dedouble_pas(self):
        # « Vayne - Hunter » gagne un tag « Sentinel » en VEN. Le vocabulaire des
        # champions écarte ce tag-là, qui n'est pas un champion.
        cards = [
            carte("Vayne - Hunter", tags=["Demacia", "Vayne"]),
            carte("Vayne - Hunter", tags=["Demacia", "Sentinel", "Vayne"]),
        ]
        assert len(identites(cards)) == 1


class TestCeQueLIdentiteSepare:
    def test_deux_champions_pour_un_meme_titre(self):
        # Les trois paires mesurées. Le titre seul les confondrait, et rien ne
        # permettrait ensuite de s'en apercevoir.
        for titre, a, b in (
            ("Hotheaded", "Rumble", "Vi"),
            ("Hunter", "Vayne", "Warwick"),
            ("Victorious", "Fiora", "Qiyana"),
        ):
            cards = [
                carte(f"{a} - {titre}", tags=[a]),
                carte(f"{b} - {titre}", tags=[b]),
            ]
            assert len(identites(cards)) == 2, titre

    def test_deux_types_pour_un_meme_titre(self):
        cards = [
            carte("Shen - Eye of Twilight", type_="Legend", tags=["Shen"]),
            carte("Shen - Eye of Twilight", type_="Unit", tags=["Shen"]),
        ]
        assert len(identites(cards)) == 2

    def test_deux_titres_du_meme_champion(self):
        cards = [
            carte("Ahri - Alluring", tags=["Ahri"]),
            carte("Ahri - Inquisitive", tags=["Ahri"]),
        ]
        assert len(identites(cards)) == 2


class TestVariantesEtNomAffiche:
    def test_une_variante_reste_la_meme_carte(self):
        # `base_name` retire « (Signature) » : une variante est une impression.
        cards = [
            carte("Master Yi - Wuju Master", tags=["Master Yi"]),
            carte("Master Yi - Wuju Master (Signature)", tags=["Master Yi"]),
        ]
        assert len(identites(cards)) == 1
        assert base_name("Master Yi - Wuju Master (Signature)") == "Master Yi - Wuju Master"

    def test_le_nom_retenu_est_le_plus_informatif(self):
        # Le plus long porte le champion. Sans cette règle, l'affichage dépendait
        # de l'ordre de pagination de la source.
        assert (
            display_name(["Matriarch of War", "Ambessa - Matriarch of War"])
            == "Ambessa - Matriarch of War"
        )

    def test_a_longueur_egale_le_choix_reste_determine(self):
        assert display_name(["Vi, Destructive", "Vi - Destructive"]) == "Vi - Destructive"
