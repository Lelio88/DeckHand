"""Tests de la résolution des noms de decklists vers le catalogue.

Les sources de decks nomment les cartes librement : casse variable, accents,
apostrophes typographiques, cartes recto-verso écrites tantôt en entier tantôt
par leur seule face avant. Une résolution trop stricte perdrait des cartes en
silence — et un deck amputé de trois cartes paraîtrait presque complet.
"""

from app.ingestion.card_resolver import CardResolver


def build() -> CardResolver:
    return CardResolver(
        {
            "lightning bolt": "oracle-bolt",
            "foudre": "oracle-bolt",
            "sol ring": "oracle-ring",
            "urza's saga": "oracle-saga",
            "delver of secrets": "oracle-delver",
            "delver of secrets // insectile aberration": "oracle-delver",
            "fire": "oracle-fire",
            "fire // ice": "oracle-fireice",
        }
    )


def test_resolves_exact_name():
    assert build().resolve("Lightning Bolt") == "oracle-bolt"


def test_resolves_regardless_of_case_and_spacing():
    assert build().resolve("  LIGHTNING   BOLT ") == "oracle-bolt"


def test_resolves_french_name():
    assert build().resolve("Foudre") == "oracle-bolt"


def test_resolves_curly_apostrophe():
    """Les exports recopient parfois l'apostrophe typographique de la carte."""
    assert build().resolve("Urza’s Saga") == "oracle-saga"


def test_resolves_double_faced_card_by_full_name():
    assert build().resolve("Delver of Secrets // Insectile Aberration") == "oracle-delver"


def test_falls_back_to_front_face_when_full_name_unknown():
    """Certaines sources écrivent le nom complet d'une carte indexée par sa face avant."""
    assert build().resolve("Sol Ring // Something Else") == "oracle-ring"


def test_prefers_full_name_over_front_face():
    """« Fire // Ice » existe comme entrée propre : ne pas le réduire à « Fire »."""
    assert build().resolve("Fire // Ice") == "oracle-fireice"


def test_returns_none_for_unknown_card():
    assert build().resolve("Carte Qui N'Existe Pas") is None


def test_returns_none_for_blank_input():
    assert build().resolve("   ") is None


def test_records_unresolved_names_for_reporting():
    """Un import ne doit jamais perdre des cartes en silence."""
    resolver = build()
    resolver.resolve("Lightning Bolt")
    resolver.resolve("Carte Inconnue")
    resolver.resolve("Carte Inconnue")
    resolver.resolve("Autre Inconnue")

    assert resolver.resolved_count == 1
    assert resolver.unresolved == {"carte inconnue": 2, "autre inconnue": 1}


def test_resolve_deck_maps_quantities_and_reports_gaps():
    resolver = build()
    resolved, missing = resolver.resolve_deck(
        {"Lightning Bolt": 4, "Sol Ring": 1, "Carte Inconnue": 2}
    )
    assert resolved == {"oracle-bolt": 4, "oracle-ring": 1}
    assert missing == 2


def test_resolve_deck_merges_duplicate_names():
    """Un même oracle_id peut apparaître deux fois via deux orthographes."""
    resolver = build()
    resolved, missing = resolver.resolve_deck({"Lightning Bolt": 2, "Foudre": 2})
    assert resolved == {"oracle-bolt": 4}
    assert missing == 0


# --- OracleResolver ---------------------------------------------------------


def test_oracle_resolver_accepts_known_identifier():
    from app.ingestion.card_resolver import OracleResolver

    resolver = OracleResolver({"oracle-bolt", "oracle-ring"})
    assert resolver.resolve("oracle-bolt") == "oracle-bolt"


def test_oracle_resolver_rejects_identifier_absent_from_catalogue():
    """Le catalogue ne retient que les cartes légales dans les formats couverts.

    Insérer un identifiant inconnu violerait la clé étrangère et ferait échouer
    tout l'import.
    """
    from app.ingestion.card_resolver import OracleResolver

    resolver = OracleResolver({"oracle-bolt"})
    assert resolver.resolve("oracle-inconnu") is None
    assert resolver.unresolved == {"oracle-inconnu": 1}


def test_oracle_resolver_handles_blank_identifier():
    from app.ingestion.card_resolver import OracleResolver

    assert OracleResolver({"a"}).resolve("") is None


def test_oracle_resolver_resolves_deck_like_the_name_resolver():
    """Interface identique : `store_deck` accepte les deux indifféremment."""
    from app.ingestion.card_resolver import OracleResolver

    resolver = OracleResolver({"oracle-bolt", "oracle-ring"})
    resolved, missing = resolver.resolve_deck(
        {"oracle-bolt": 4, "oracle-ring": 1, "oracle-inconnu": 3}
    )
    assert resolved == {"oracle-bolt": 4, "oracle-ring": 1}
    assert missing == 3
