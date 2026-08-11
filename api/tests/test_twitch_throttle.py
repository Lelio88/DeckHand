"""Le débit, vérifié en avançant l'horloge plutôt qu'en attendant.

**Ce que ces tests protègent est le canal, pas le bot.** Franchir le plafond
Twitch vaut une exclusion temporaire : le bot se tait alors pour tout le monde,
pendant l'émission. Une limite de trente secondes vérifiée en dormant trente
secondes ne serait vérifiée par personne — d'où l'horloge injectée.
"""

from __future__ import annotations

from app.twitch.throttle import Throttle


class FakeClock:
    """Le temps, avancé à la main."""

    def __init__(self) -> None:
        self.now = 1000.0

    def __call__(self) -> float:
        return self.now

    def advance(self, seconds: float) -> None:
        self.now += seconds


def throttle(clock: FakeClock, **overrides: float | int) -> Throttle:
    options: dict[str, float | int] = {
        "burst": 3,
        "window_seconds": 30.0,
        "user_cooldown_seconds": 5.0,
        "query_cooldown_seconds": 30.0,
    }
    options.update(overrides)
    return Throttle(clock=clock, **options)  # type: ignore[arg-type]


class TestThrottle:
    def test_le_premier_passage_est_accorde(self) -> None:
        clock = FakeClock()
        assert throttle(clock).allows("alice", "ka-zar") is True

    def test_le_plafond_se_ferme_puis_se_rouvre(self) -> None:
        clock = FakeClock()
        limit = throttle(clock)
        for index in range(3):
            assert limit.allows(f"viewer{index}", f"carte{index}") is True
            clock.advance(6)
        assert limit.allows("viewer9", "carte9") is False, "plafond atteint"

        # La fenêtre glisse : le plus ancien envoi sort au bout de 30 s.
        clock.advance(13)
        assert limit.allows("viewer9", "carte9") is True

    def test_un_spectateur_ne_monopolise_pas_le_bot(self) -> None:
        clock = FakeClock()
        limit = throttle(clock)
        assert limit.allows("alice", "ka-zar") is True
        clock.advance(1)
        assert limit.allows("alice", "hulk") is False
        clock.advance(5)
        assert limit.allows("alice", "hulk") is True

    def test_le_pseudo_se_compare_sans_egard_a_la_casse(self) -> None:
        clock = FakeClock()
        limit = throttle(clock)
        assert limit.allows("Alice", "ka-zar") is True
        assert limit.allows("alice", "hulk") is False

    def test_la_meme_recherche_ne_se_reecrit_pas(self) -> None:
        # Vingt personnes demandent la même carte après l'avoir vue passer :
        # la réponse est encore à l'écran.
        clock = FakeClock()
        limit = throttle(clock)
        assert limit.allows("alice", "Ka-Zar") is True
        clock.advance(10)
        assert limit.allows("bob", "  ka-zar ") is False, (
            "même recherche, casse et espaces mis à part"
        )
        clock.advance(21)
        assert limit.allows("carol", "ka-zar") is True

    def test_decider_c_est_enregistrer(self) -> None:
        # Interroger sans enregistrer laisserait deux commandes simultanées
        # passer toutes les deux.
        clock = FakeClock()
        limit = throttle(clock, burst=1)
        assert limit.allows("alice", "ka-zar") is True
        assert limit.allows("bob", "hulk") is False

    def test_les_tables_ne_grandissent_pas_indefiniment(self) -> None:
        # Un direct de plusieurs heures verrait sinon une entrée par spectateur
        # croisé depuis le début.
        clock = FakeClock()
        limit = throttle(clock, burst=10_000)
        for index in range(50):
            limit.allows(f"viewer{index}", f"carte{index}")
            clock.advance(1)
        clock.advance(120)
        limit.allows("dernier", "derniere")
        assert len(limit._last_by_user) == 1
        assert len(limit._last_by_query) == 1
