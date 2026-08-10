"""Tests de la transformation des payloads Scryfall vers les modèles DeckHand.

Aucun appel réseau : les payloads sont des extraits figés de réponses réelles.
"""

import pytest

from app.ingestion.scryfall_parse import (
    RELEVANT_FORMATS,
    is_relevant,
    should_ingest,
    normalize_name,
    parse_card,
    parse_print,
    search_names_for,
)


# --- normalize_name ---------------------------------------------------------


def test_normalize_name_strips_accents():
    assert normalize_name("Île") == "ile"
    assert normalize_name("Forêt") == "foret"


def test_normalize_name_is_case_insensitive():
    assert normalize_name("Lightning Bolt") == "lightning bolt"


def test_normalize_name_unifies_curly_and_straight_apostrophes():
    assert normalize_name("Urza's Saga") == normalize_name("Urza’s Saga")


def test_normalize_name_collapses_surrounding_whitespace():
    assert normalize_name("  Sol   Ring  ") == "sol ring"


# --- is_relevant ------------------------------------------------------------


def test_relevant_formats_are_the_three_covered_ones():
    assert RELEVANT_FORMATS == ("pauper", "modern", "commander")


def test_is_relevant_when_legal_in_at_least_one_covered_format():
    assert is_relevant({"pauper": "not_legal", "modern": "legal", "commander": "legal"})
    assert is_relevant({"pauper": "legal"})


def test_is_relevant_false_when_legal_in_no_covered_format():
    assert not is_relevant({"standard": "legal", "modern": "banned", "commander": "banned"})
    assert not is_relevant({})


def test_banned_is_not_legal():
    assert not is_relevant({"modern": "banned", "commander": "banned", "pauper": "banned"})


# --- should_ingest ----------------------------------------------------------


def test_a_playable_card_enters_the_catalogue():
    assert should_ingest({"layout": "normal", "legalities": {"pauper": "legal"}})


def test_a_token_enters_the_catalogue_although_it_is_legal_nowhere():
    # Un jeton ne se joue dans aucun format, mais il occupe une case de
    # classeur : l'exclure rendait une collection physique impossible à saisir
    # en entier.
    for layout in ("token", "double_faced_token", "emblem"):
        assert should_ingest({"layout": layout, "legalities": {}})


def test_an_unplayable_card_that_is_not_a_token_stays_out():
    assert not should_ingest({"layout": "normal", "legalities": {"standard": "legal"}})
    assert not should_ingest({"layout": "art_series", "legalities": {}})


def test_a_token_keeps_no_legality():
    # C'est ce qui le tient à l'écart des suggestions de decks sans qu'aucun
    # garde-fou supplémentaire soit nécessaire : le moteur travaille sur les
    # colonnes de légalité, toutes fausses ici.
    assert not is_relevant({})


# --- payloads de référence --------------------------------------------------


@pytest.fixture
def bolt_en():
    """Carte anglaise ordinaire."""
    return {
        "object": "card",
        "id": "77c6fa74-5543-42ac-9ead-0e890b188e99",
        "oracle_id": "4457ed35-7c10-48c8-9776-456485fdf070",
        "name": "Lightning Bolt",
        "lang": "en",
        "mana_cost": "{R}",
        "cmc": 1.0,
        "type_line": "Instant",
        "oracle_text": "Lightning Bolt deals 3 damage to any target.",
        "color_identity": ["R"],
        "legalities": {"modern": "legal", "pauper": "legal", "commander": "legal"},
        "layout": "normal",
        "set": "2x2",
        "set_name": "Double Masters 2022",
        "collector_number": "117",
        "rarity": "uncommon",
        "image_uris": {"art_crop": "https://cards.scryfall.io/art_crop/bolt.jpg"},
        "prices": {"usd": "2.50", "eur": "1.80", "usd_foil": "9.99"},
        "released_at": "2022-07-08",
    }


@pytest.fixture
def island_fr():
    """Impression française : le nom imprimé diffère du nom oracle."""
    return {
        "object": "card",
        "id": "aaaaaaaa-1111-2222-3333-444444444444",
        "oracle_id": "b2c6aa39-2d2a-459c-a5cc-1cbbc6e0bcc7",
        "name": "Island",
        "printed_name": "Île",
        "lang": "fr",
        "mana_cost": "",
        "cmc": 0.0,
        "type_line": "Basic Land — Island",
        "color_identity": [],
        "legalities": {"modern": "legal", "pauper": "legal", "commander": "legal"},
        "layout": "normal",
        "set": "dom",
        "set_name": "Dominaria",
        "collector_number": "265",
        "rarity": "common",
        "image_uris": {"art_crop": "https://cards.scryfall.io/art_crop/ile.jpg"},
        "prices": {"usd": None, "eur": "0.15"},
        "released_at": "2018-04-27",
    }


@pytest.fixture
def double_faced():
    """Carte recto-verso : l'illustration vit dans card_faces, pas à la racine."""
    return {
        "object": "card",
        "id": "cccccccc-1111-2222-3333-444444444444",
        "oracle_id": "dddddddd-1111-2222-3333-444444444444",
        "name": "Delver of Secrets // Insectile Aberration",
        "lang": "en",
        "cmc": 1.0,
        "type_line": "Creature — Human Wizard",
        "color_identity": ["U"],
        "legalities": {"modern": "legal", "pauper": "legal", "commander": "legal"},
        "layout": "transform",
        "set": "isd",
        "set_name": "Innistrad",
        "collector_number": "51",
        "rarity": "common",
        "card_faces": [
            {
                "name": "Delver of Secrets",
                "image_uris": {"art_crop": "https://cards.scryfall.io/art_crop/delver.jpg"},
            },
            {"name": "Insectile Aberration"},
        ],
        "prices": {"usd": "0.30", "eur": "0.25"},
        "released_at": "2011-09-30",
    }


# --- parse_card -------------------------------------------------------------


def test_parse_card_maps_core_fields(bolt_en):
    card = parse_card(bolt_en)
    assert card.oracle_id == "4457ed35-7c10-48c8-9776-456485fdf070"
    assert card.name == "Lightning Bolt"
    assert card.cmc == 1.0
    assert card.color_identity == ["R"]
    assert card.legalities["pauper"] == "legal"


def test_parse_card_uses_oracle_name_even_for_localized_printing(island_fr):
    """Le nom oracle anglais fait foi : les decklists sont en anglais."""
    card = parse_card(island_fr)
    assert card.name == "Island"


def test_parse_card_defaults_missing_cmc_to_zero():
    card = parse_card({"oracle_id": "x", "name": "Nameless", "legalities": {}})
    assert card.cmc == 0


def test_parse_card_rejects_payload_without_oracle_id():
    with pytest.raises(ValueError, match="oracle_id"):
        parse_card({"name": "Broken", "legalities": {}})


# --- parse_print ------------------------------------------------------------


def test_parse_print_maps_edition_and_prices(bolt_en):
    p = parse_print(bolt_en)
    assert p.scryfall_id == "77c6fa74-5543-42ac-9ead-0e890b188e99"
    assert p.set_code == "2x2"
    assert p.rarity == "uncommon"
    assert p.price_eur == 1.80
    assert p.price_usd == 2.50
    assert p.art_crop_url == "https://cards.scryfall.io/art_crop/bolt.jpg"


def test_parse_print_keeps_printed_name_for_localized_card(island_fr):
    p = parse_print(island_fr)
    assert p.lang == "fr"
    assert p.printed_name == "Île"


def test_parse_print_handles_absent_prices(island_fr):
    p = parse_print(island_fr)
    assert p.price_usd is None
    assert p.price_eur == 0.15


def test_parse_print_finds_art_on_first_face_of_double_faced_card(double_faced):
    p = parse_print(double_faced)
    assert p.art_crop_url == "https://cards.scryfall.io/art_crop/delver.jpg"


def test_parse_print_tolerates_missing_art():
    p = parse_print(
        {"id": "i", "oracle_id": "o", "lang": "en", "set": "s", "prices": {}}
    )
    assert p.art_crop_url is None


# --- search_names_for -------------------------------------------------------


def test_search_names_yields_oracle_name_for_english_printing(bolt_en):
    names = search_names_for(bolt_en)
    assert ("Lightning Bolt", "lightning bolt", "en") in names


def test_search_names_yields_both_oracle_and_printed_name(island_fr):
    """Saisir "Île" ou "Island" doit mener à la même carte."""
    names = search_names_for(island_fr)
    normalized = {n for _, n, _ in names}
    assert "island" in normalized
    assert "ile" in normalized


def test_search_names_deduplicates_when_printed_equals_oracle(bolt_en):
    assert len(search_names_for(bolt_en)) == 1


def test_search_names_indexes_each_face_of_a_double_faced_card(double_faced):
    """Les decklists nomment ces cartes par leur seule face avant.

    Sans entrée pour « Delver of Secrets », la résolution d'une decklist échoue
    et l'utilisateur qui tape ce nom ne trouve rien.
    """
    normalized = {n for _, n, _ in search_names_for(double_faced)}
    assert "delver of secrets // insectile aberration" in normalized
    assert "delver of secrets" in normalized
    assert "insectile aberration" in normalized


def test_search_names_does_not_duplicate_face_equal_to_full_name():
    """Une carte mono-face déclarant `card_faces` ne doit pas produire de doublon."""
    payload = {
        "name": "Solo Face",
        "lang": "en",
        "card_faces": [{"name": "Solo Face"}],
    }
    assert len(search_names_for(payload)) == 1
