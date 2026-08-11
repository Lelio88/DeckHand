"""Ce que le bot dit, et ce qu'il refuse de dire.

Deux enjeux. Le premier est **l'anti-énumération** : une carte absente, une
adresse inconnue et une extension retirée du partage doivent produire la même
phrase, sinon le bot devient l'oracle qui dit quelles collections existent.

Le second est la **reconnaissance de la commande** : `!cards` ne doit pas
déclencher `!card`, et `!card` seul ne doit rien déclencher du tout — répondre
« pas dans le classeur » à une commande sans argument serait faux.
"""

from __future__ import annotations

from app.twitch.reply import Location, format_reply, parse_command


def place(**overrides: object) -> Location:
    base = {
        "name": "Ka-Zar of the Savage Land",
        "matched_name": "Ka-Zar of the Savage Land",
        "set_name": "Marvel Super Heroes",
        "collector_number": "174",
        "page": 20,
        "slot": 3,
        "copies": 1,
        "has_foil": False,
    }
    return Location.from_row({**base, **overrides})


class TestFormatReply:
    def test_une_case_se_dit_en_entier(self) -> None:
        assert format_reply("ka-zar", [place()]) == (
            "Ka-Zar of the Savage Land — Marvel Super Heroes #174, page 20 case 3"
        )

    def test_le_nombre_d_exemplaires_n_apparait_qu_au_pluriel(self) -> None:
        assert "×4" in format_reply("ile", [place(copies=4)])
        assert "×1" not in format_reply("ka-zar", [place(copies=1)])

    def test_le_brillant_se_signale(self) -> None:
        assert "brillante" in format_reply("ka-zar", [place(has_foil=True)])

    def test_le_nom_rendu_est_celui_trouve_pas_celui_tape(self) -> None:
        # Demander « ile » et s'entendre répondre « Island » donnerait
        # l'impression d'une autre carte.
        reply = format_reply("ile", [place(name="Island", matched_name="Île")])
        assert reply.startswith("Île —")

    def test_le_debordement_est_compte_jamais_tronque_en_silence(self) -> None:
        many = [place(page=n, slot=1) for n in range(1, 7)]
        reply = format_reply("ile", many)
        assert reply.count(" · ") == 2, "trois emplacements au plus"
        assert "(+3 autres)" in reply

    def test_un_seul_surnombre_se_dit_au_singulier(self) -> None:
        reply = format_reply("ile", [place(page=n) for n in range(1, 5)])
        assert "(+1 autre)" in reply

    def test_rien_a_dire_se_dit_pareil_quelle_qu_en_soit_la_cause(self) -> None:
        # Carte non possédée, adresse inconnue, extension non partagée : le
        # bot ne sait pas laquelle, et ne doit pas pouvoir le laisser deviner.
        assert format_reply("Black Lotus", []) == "« Black Lotus » : pas dans le classeur."
        assert format_reply("  Black Lotus  ", []) == "« Black Lotus » : pas dans le classeur."


class TestParseCommand:
    def test_la_commande_rend_sa_recherche(self) -> None:
        assert parse_command("!card Ka-Zar") == "Ka-Zar"

    def test_la_casse_et_les_espaces_de_tete_sont_tolores(self) -> None:
        assert parse_command("  !CARD   Ka-Zar  ") == "Ka-Zar"

    def test_un_prefixe_plus_long_n_est_pas_la_commande(self) -> None:
        assert parse_command("!cards Ka-Zar") is None

    def test_sans_argument_rien_ne_se_declenche(self) -> None:
        assert parse_command("!card") is None
        assert parse_command("!card   ") is None

    def test_une_phrase_ordinaire_passe_sans_bruit(self) -> None:
        assert parse_command("j'ai une carte !card-like") is None
