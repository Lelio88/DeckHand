"""Les commandes ajoutées au bot, jouées sans réseau (#21).

**Ce que ces tests protègent.** D'abord qu'une commande sans argument se
distingue d'une phrase qui commence par le même mot : `!classeur de mon ami` ne
doit rien déclencher, sans quoi le bot répondrait à des conversations.

Ensuite que le **débit** s'applique à ces commandes comme aux autres. Elles sont
plus tentantes à répéter que `!card` — elles n'ont rien à taper — et une réponse
identique dix fois d'affilée est exactement ce qu'un chat modère.

Et enfin que `!deckhand` ne **prétende pas** partager un classeur qui ne l'est
pas : annoncer une adresse qui ne mène nulle part vaut moins que se taire.
"""

from __future__ import annotations

import httpx

from app.twitch.bot import Bot
from app.twitch.irc import ChatMessage
from app.twitch.locator import Locator
from app.twitch.reply import (
    Addition,
    Cell,
    Location,
    Shelf,
    format_page,
    format_prix,
    format_recent,
    format_reply,
    format_shelf,
    parse_bare_command,
    parse_page_command,
)
from app.twitch.throttle import Throttle


class FauxLocator(Locator):
    """Un locator qui ne touche à rien, et qui note ce qu'on lui demande."""

    def __init__(
        self,
        *,
        recentes: list[Addition] | None = None,
        rayonnage: list[Shelf] | None = None,
        places: list[Location] | None = None,
        accepte: bool = True,
        cases: list[Cell] | None = None,
    ) -> None:
        super().__init__(supabase_url="https://x", anon_key="k", handle="lelio")
        object.__setattr__(self, "_recentes", recentes or [])
        object.__setattr__(self, "_rayonnage", rayonnage or [])
        object.__setattr__(self, "_places", places or [])
        object.__setattr__(self, "_accepte", accepte)
        object.__setattr__(self, "_cases", cases)
        object.__setattr__(self, "appels", [])

    def recent(self, client: httpx.Client, limit: int = 3) -> list[Addition]:
        self.appels.append("recent")
        return self._recentes

    def shelf(self, client: httpx.Client) -> list[Shelf]:
        self.appels.append("shelf")
        return self._rayonnage

    def page(
        self, client: httpx.Client, set_code: str, page: int, per_page: int = 9
    ) -> list[Cell]:
        self.appels.append(f"page:{set_code}:{page}")
        if self._cases is not None:
            return self._cases
        return [Cell(str(n), f"Carte {n}", 1 if n < 5 else 0) for n in range(1, 10)]

    def locate(self, client: httpx.Client, query: str) -> list[Location]:
        self.appels.append(f"locate:{query}")
        return self._places

    def designate(
        self,
        client: httpx.Client,
        set_code: str,
        collector_number: str,
        requested_by: str,
    ) -> bool:
        self.appels.append(f"designate:{set_code}:{collector_number}:{requested_by}")
        return self._accepte

    def designate_page(
        self, client: httpx.Client, set_code: str, page: int, requested_by: str
    ) -> bool:
        self.appels.append(f"designate_page:{set_code}:{page}:{requested_by}")
        return self._accepte

    def designate_strip(
        self,
        client: httpx.Client,
        set_code: str,
        collector_number: str,
        requested_by: str,
    ) -> bool:
        self.appels.append(f"designate_strip:{set_code}:{collector_number}")
        return self._accepte


def une_addition(nom: str = "Shuri", numero: str = "75") -> Addition:
    return Addition(
        name="Shuri, Wakandan Inventor",
        printed_name=nom,
        set_code="msh",
        collector_number=numero,
    )


def une_etagere(code: str = "msh", possedees: int = 234, total: int = 453) -> Shelf:
    return Shelf(
        set_code=code,
        set_name="Marvel Super Heroes" if code == "msh" else code.upper(),
        total_cells=total,
        owned_cells=possedees,
    )


def une_place(nom: str = "Ka-Zar", numero: str = "185") -> Location:
    return Location(
        name=nom,
        matched_name=nom,
        set_name="Marvel Super Heroes",
        set_code="msh",
        collector_number=numero,
        page=3,
        slot=4,
        copies=1,
        has_foil=False,
    )


class TestReconnaissance:
    def test_la_commande_seule_declenche(self) -> None:
        assert parse_bare_command("!classeur", "!classeur")
        assert parse_bare_command("  !CLASSEUR  ", "!classeur")

    def test_une_phrase_qui_commence_pareil_ne_declenche_pas(self) -> None:
        """**La différence avec `!card`.** Celle-ci exige un argument ; celles-ci
        exigent l'inverse. Sans quoi « !classeur de mon ami est mieux rangé »
        ferait répondre le bot au milieu d'une conversation."""
        assert not parse_bare_command("!classeur de mon ami", "!classeur")
        assert not parse_bare_command("!classeurs", "!classeur")


class TestFormes:
    def test_les_dernieres_montrent_le_nom_imprime(self) -> None:
        """Répondre « Island » à qui vient de voir « Île » donnerait
        l'impression d'une autre carte."""
        phrase = format_recent([une_addition(nom="Île")])
        assert "Île" in phrase
        assert "MSH 75" in phrase

    def test_ce_qui_deborde_est_compte_jamais_tronque(self) -> None:
        phrase = format_recent([une_addition(numero=str(n)) for n in range(6)])
        assert "+3 autres" in phrase

    def test_un_classeur_vide_se_dit_sans_mentir(self) -> None:
        """Rien à montrer et rien de partagé se disent pareil : distinguer
        confirmerait l'existence d'une collection fermée."""
        assert "pas encore partagé" in format_shelf([])
        assert "rien d'ajouté" in format_recent([])

    def test_le_rayonnage_donne_le_compte_par_extension(self) -> None:
        phrase = format_shelf([une_etagere(), une_etagere("ltr", 88, 281)])
        assert "Marvel Super Heroes 234/453" in phrase
        assert "LTR 88/281" in phrase


class TestBot:
    def _bot(self, **kwargs: object) -> Bot:
        defauts: dict[str, object] = {
            "locator": FauxLocator(recentes=[une_addition()], rayonnage=[une_etagere()]),
            "channel": "lelio",
        }
        defauts.update(kwargs)
        return Bot(**defauts)  # type: ignore[arg-type]

    def test_dernieres_repond(self) -> None:
        bot = self._bot()
        reply = bot.answer(ChatMessage("alice", "#lelio", "!dernieres"), httpx.Client())
        assert reply is not None
        assert reply.startswith("@alice")
        assert "Shuri" in reply

    def test_classeur_repond(self) -> None:
        bot = self._bot()
        reply = bot.answer(ChatMessage("alice", "#lelio", "!classeur"), httpx.Client())
        assert reply is not None
        assert "234/453" in reply

    def test_deckhand_ne_touche_pas_au_reseau(self) -> None:
        locator = FauxLocator()
        bot = self._bot(locator=locator, share_url="https://exemple/?c=abc")
        reply = bot.answer(ChatMessage("a", "#lelio", "!deckhand"), httpx.Client())
        assert reply is not None
        assert "https://exemple/?c=abc" in reply
        # §IV.2 : l'attribution doit être visible de qui regarde.
        assert "Scryfall" in reply
        assert locator.appels == []

    def test_deckhand_ne_promet_pas_un_classeur_non_partage(self) -> None:
        bot = self._bot(share_url="")
        reply = bot.answer(ChatMessage("a", "#lelio", "!deckhand"), httpx.Client())
        assert reply is not None
        assert "non partagé" in reply
        assert "http" not in reply

    def test_le_debit_s_applique_aussi_a_ces_commandes(self) -> None:
        """Elles n'ont rien à taper, donc elles se répètent — et une réponse
        identique dix fois d'affilée est ce qu'un chat modère."""
        bot = self._bot(throttle=Throttle(burst=1, window_seconds=60.0))
        assert bot.answer(ChatMessage("a", "#lelio", "!classeur"), httpx.Client())
        assert bot.answer(ChatMessage("b", "#lelio", "!dernieres"), httpx.Client()) is None

    def test_un_autre_canal_ne_declenche_rien(self) -> None:
        bot = self._bot()
        assert bot.answer(ChatMessage("a", "#autre", "!classeur"), httpx.Client()) is None

    def test_card_repond_toujours(self) -> None:
        """**La commande d'origine n'est pas devenue une branche morte.** Le
        routeur essaie `!card` en premier ; une erreur d'ordre l'aurait fait
        tomber dans les commandes sans argument, qui l'auraient ignorée."""
        locator = FauxLocator()
        bot = self._bot(locator=locator)
        reply = bot.answer(
            ChatMessage("a", "#lelio", "!card Ka-Zar"),
            httpx.Client(transport=httpx.MockTransport(lambda _r: httpx.Response(200, json=[]))),
        )
        assert reply is not None
        assert "Ka-Zar" in reply


class TestRoutagePage:
    def test_page_repond_et_demande_la_bonne_page(self) -> None:
        locator = FauxLocator()
        bot = Bot(locator=locator, channel="lelio")
        reply = bot.answer(ChatMessage("a", "#lelio", "!page msh 3"), httpx.Client())
        assert reply is not None
        assert "MSH page 3 : 4/9 cases" in reply
        # **Lire puis écrire** : la page est lue par la porte publique, qui
        # applique la portée, et n_est montée à l_écran qu_ensuite.
        assert locator.appels == ["page:msh:3", "designate_page:msh:3:a"]

    def test_une_saisie_incomprise_ne_touche_pas_au_reseau(self) -> None:
        """**Renoncer, c'est aussi ne pas appeler.** Une commande mal formée
        qui interrogerait quand même consommerait le débit pour rien."""
        locator = FauxLocator()
        bot = Bot(locator=locator, channel="lelio")
        assert bot.answer(ChatMessage("a", "#lelio", "!page msh bidule"), httpx.Client()) is None
        assert locator.appels == []


class TestPage:
    """`!page <extension> <n>` — ce qui manque à une page.

    **C'est `!manque` ramené à une échelle où il a une réponse.** Sur une
    extension entière il manque des centaines de cases, et aucune troncature
    n'en fait une phrase utile ; une page en compte neuf au plus, et ses vides
    se nomment tous.
    """

    def test_l_extension_seule_vaut_la_premiere_page(self) -> None:
        """Exiger le numéro ferait échouer la forme la plus naturelle."""
        assert parse_page_command("!page msh") == ("msh", 1)

    def test_le_numero_est_lu_quand_il_est_la(self) -> None:
        assert parse_page_command("!page msh 3") == ("msh", 3)

    def test_un_second_mot_qui_n_est_pas_un_nombre_fait_renoncer(self) -> None:
        """**Ne pas inventer la question.** Répondre sur la page 1 à
        « !page msh bidule » répondrait à autre chose que ce qui est demandé."""
        assert parse_page_command("!page msh bidule") is None
        assert parse_page_command("!page msh 0") is None
        assert parse_page_command("!page msh 3 4") is None

    def test_la_commande_sans_argument_ne_declenche_rien(self) -> None:
        assert parse_page_command("!page") is None
        assert parse_page_command("!pages msh") is None

    def test_les_cases_vides_sont_nommees_par_leur_numero(self) -> None:
        cellules = [
            Cell(collector_number=str(n), name=f"Carte {n}", owned=1 if n % 2 else 0)
            for n in range(1, 10)
        ]
        phrase = format_page("msh", 3, cellules)
        assert "MSH page 3 : 5/9 cases" in phrase
        assert "#2" in phrase and "#8" in phrase

    def test_une_page_complete_le_dit(self) -> None:
        cellules = [Cell(str(n), f"Carte {n}", 1) for n in range(1, 10)]
        assert "complète" in format_page("msh", 1, cellules)

    def test_une_page_hors_partage_se_tait_comme_le_reste(self) -> None:
        """Extension non partagée, adresse inconnue, page au-delà de la
        dernière : la même phrase. C'est l'anti-énumération du projet."""
        assert "rien à la page 99" in format_page("msh", 99, [])


class TestPrix:
    def test_le_prix_suit_la_localisation(self) -> None:
        place = Location(
            name="Ka-Zar",
            matched_name="Ka-Zar",
            set_name="Marvel Super Heroes",
            set_code="msh",
            collector_number="185",
            page=3,
            slot=4,
            copies=1,
            has_foil=False,
            price_eur=2.4,
        )
        phrase = format_reply("ka-zar", [place])
        assert "page 3 case 4" in phrase
        assert "2,40 €" in phrase

    def test_une_carte_sans_cote_n_affiche_pas_zero(self) -> None:
        """**Rien plutôt que zéro.** Scryfall ne cote pratiquement que
        l'anglais : « 0,00 € » ferait croire à une carte sans valeur là où l'on
        ne sait simplement pas."""
        place = Location(
            name="Ka-Zar",
            matched_name="Ka-Zar",
            set_name="Marvel Super Heroes",
            set_code="msh",
            collector_number="185",
            page=3,
            slot=4,
            copies=1,
            has_foil=False,
            price_eur=None,
        )
        phrase = format_reply("ka-zar", [place])
        assert "€" not in phrase
        assert format_prix(None) == ""

    def test_le_prix_cohabite_avec_les_autres_marques(self) -> None:
        place = Location(
            name="Ka-Zar",
            matched_name="Ka-Zar",
            set_name="MSH",
            set_code="msh",
            collector_number="185",
            page=3,
            slot=4,
            copies=2,
            has_foil=True,
            price_eur=12.0,
        )
        phrase = format_reply("ka-zar", [place])
        assert "×2" in phrase and "brillante" in phrase and "12,00 €" in phrase

    def test_une_ligne_sans_prix_se_lit_sans_erreur(self) -> None:
        """La colonne est neuve : un relevé d'avant la migration n'en porte
        pas, et `from_row` ne doit pas y voir un zéro."""
        assert Location.from_row({"name": "x"}).price_eur is None
        assert Location.from_row({"name": "x", "price_eur": "2.40"}).price_eur == 2.4


class TestDesignation:
    """`!montre <nom>` — la seule commande qui écrive.

    **Ce que ces tests protègent avant tout, c'est l'ordre lecture → écriture.**
    La commande n'a aucun contrôle de portée à elle : elle s'appuie sur le fait
    que `binder_locate` ne rend que ce que le propriétaire partage. Si elle
    écrivait avant de lire — ou même sans avoir rien lu — ce raisonnement
    tomberait, et rien d'autre ne le rattraperait.
    """

    def _bot(self, **kwargs: object) -> Bot:
        defauts: dict[str, object] = {"channel": "lelio"}
        defauts.update(kwargs)
        return Bot(**defauts)  # type: ignore[arg-type]

    def test_la_carte_monte_a_l_ecran(self) -> None:
        locator = FauxLocator(places=[une_place()])
        bot = self._bot(locator=locator)
        reply = bot.answer(ChatMessage("alice", "#lelio", "!montre ka-zar"), httpx.Client())
        assert reply is not None
        assert "Ka-Zar" in reply and "à l'écran" in reply
        assert locator.appels == ["locate:ka-zar", "designate:msh:185:alice"]

    def test_une_carte_absente_n_ecrit_rien(self) -> None:
        """**Le test qui tient tout le raisonnement de sécurité.** Écrire sans
        avoir trouvé la carte reviendrait à écrire sans avoir vérifié la portée
        — et le seul contrôle de portée du chantier est celui de la lecture."""
        locator = FauxLocator(places=[])
        bot = self._bot(locator=locator)
        reply = bot.answer(ChatMessage("alice", "#lelio", "!montre bidule"), httpx.Client())
        assert reply is not None
        assert "pas dans le classeur" in reply
        assert locator.appels == ["locate:bidule"]

    def test_un_refus_de_la_base_dit_quoi_faire(self) -> None:
        """**Un refus de débit est un silence, celui-ci non.** La commande a été
        acceptée et la recherche a eu lieu : se taire laisserait croire à une
        panne."""
        locator = FauxLocator(places=[une_place()], accepte=False)
        bot = self._bot(locator=locator)
        reply = bot.answer(ChatMessage("alice", "#lelio", "!montre ka-zar"), httpx.Client())
        assert reply is not None
        assert "réessaie" in reply
        assert "à l'écran" not in reply

    def test_la_premiere_case_monte_et_pas_les_trois(self) -> None:
        """L'overlay n'a qu'une place ; `!card` en montre jusqu'à trois parce
        qu'un terrain de base occupe une douzaine de cases."""
        locator = FauxLocator(
            places=[une_place(numero="185"), une_place(numero="186")]
        )
        bot = self._bot(locator=locator)
        bot.answer(ChatMessage("alice", "#lelio", "!montre ka-zar"), httpx.Client())
        assert locator.appels == ["locate:ka-zar", "designate:msh:185:alice"]

    def test_la_commande_sans_argument_ne_declenche_rien(self) -> None:
        locator = FauxLocator(places=[une_place()])
        bot = self._bot(locator=locator)
        assert bot.answer(ChatMessage("a", "#lelio", "!montre"), httpx.Client()) is None
        assert bot.answer(ChatMessage("a", "#lelio", "!montres ka-zar"), httpx.Client()) is None
        assert locator.appels == []

    def test_le_debit_s_applique_avant_l_ecriture(self) -> None:
        """Le débit se vérifie **avant** l'appel réseau : une commande qui n'a
        pas mérité de réponse ne doit pas non plus écrire."""
        locator = FauxLocator(places=[une_place()])
        bot = self._bot(locator=locator, throttle=Throttle(burst=1, window_seconds=60.0))
        assert bot.answer(ChatMessage("a", "#lelio", "!montre ka-zar"), httpx.Client())
        assert bot.answer(ChatMessage("b", "#lelio", "!montre shuri"), httpx.Client()) is None
        assert locator.appels == ["locate:ka-zar", "designate:msh:185:a"]

    def test_card_ne_designe_jamais(self) -> None:
        """**La commande de lecture reste en lecture.** Une erreur d'ordre dans
        le routeur ferait écrire `!card`, ce qu'aucune de ses phrases ne
        signalerait."""
        locator = FauxLocator(places=[une_place()])
        bot = self._bot(locator=locator)
        bot.answer(ChatMessage("a", "#lelio", "!card ka-zar"), httpx.Client())
        assert locator.appels == ["locate:ka-zar"]


class TestPageALEcran:
    """`!page` répond **et** fait monter la page sur le calque.

    **L'ordre est la sécurité**, comme pour `!montre` : on lit d'abord par la
    porte publique — qui applique la portée —, on n'écrit qu'ensuite. Ces tests
    tiennent cet ordre, parce qu'une inversion ne casse rien de visible : la
    page s'afficherait quand même, simplement on aurait montré une extension
    qu'on n'avait pas le droit de voir.
    """

    def _bot(self, **kwargs: object) -> tuple[Bot, FauxLocator]:
        locator = FauxLocator(**kwargs)  # type: ignore[arg-type]
        return Bot(locator=locator, channel="lelio", throttle=Throttle()), locator

    def test_une_page_lue_monte_a_l_ecran(self) -> None:
        bot, locator = self._bot()
        with httpx.Client() as client:
            reponse = bot.answer(ChatMessage("viewer", "#lelio", "!page msh 3"), client)
        assert reponse is not None
        assert "MSH page 3" in reponse
        assert "À l'écran." in reponse
        assert "designate_page:msh:3:viewer" in locator.appels

    def test_la_lecture_precede_l_ecriture(self) -> None:
        # **Le contrôle qui vaut pour la sécurité.** Écrire avant de lire
        # laisserait monter une page d'une extension retirée du partage : la
        # portée s'applique à la lecture, et c'est elle qui doit trancher.
        bot, locator = self._bot()
        with httpx.Client() as client:
            bot.answer(ChatMessage("viewer", "#lelio", "!page msh 3"), client)
        assert locator.appels.index("page:msh:3") < locator.appels.index(
            "designate_page:msh:3:viewer"
        )

    def test_une_page_vide_ne_monte_pas(self) -> None:
        # Extension inconnue, page hors bornes, classeur non partagé : la
        # lecture ne rend rien, et **rien n'est écrit**. Un calque ouvert sur
        # une page vide serait pire qu'un calque muet.
        bot, locator = self._bot(cases=[])
        with httpx.Client() as client:
            reponse = bot.answer(ChatMessage("viewer", "#lelio", "!page msh 999"), client)
        assert reponse is not None
        assert "rien à la page 999" in reponse
        assert not any(a.startswith("designate_page") for a in locator.appels)

    def test_l_ecran_pris_le_dit(self) -> None:
        # Le refus dit quoi faire : le spectateur a déjà sa réponse, et un
        # silence lui ferait croire à une panne.
        bot, locator = self._bot(accepte=False)
        with httpx.Client() as client:
            reponse = bot.answer(ChatMessage("viewer", "#lelio", "!page msh 3"), client)
        assert reponse is not None
        assert "écran occupé" in reponse
        # La ligne reste utile : les trous sont nommés dans les deux cas.
        assert "manquent" in reponse


class TestCardTapis:
    """`!card` pose un tapis quand la carte a plusieurs dessins possédés.

    **Le verrou est ce qui rend la commande vivable.** `!card` est la commande
    banale, tapée sans y penser ; si chaque appel prenait l'écran, le calque ne
    se reposerait jamais et `!montre` n'aurait plus de raison d'être. Ces tests
    tiennent les deux bords : le tapis monte quand il apprend quelque chose, et
    ne monte pas sinon.
    """

    def _place(self, numero: str) -> Location:
        return Location(
            name="Forest",
            matched_name="Forêt",
            set_code="msh",
            set_name="Marvel Super Heroes",
            collector_number=numero,
            page=1,
            slot=1,
            copies=1,
            has_foil=False,
        )

    def test_une_seule_case_ne_prend_pas_l_ecran(self) -> None:
        # **Le raccourci qui garde `!card` gratuite.** Une seule case possédée
        # ne peut pas porter deux dessins : inutile d_appeler la base.
        locator = FauxLocator(places=[self._place("285")])
        bot = Bot(locator=locator, channel="lelio")
        reply = bot.answer(ChatMessage("a", "#lelio", "!card foret"), httpx.Client())
        assert reply is not None
        assert "À l'écran" not in reply
        assert not any(a.startswith("designate_strip") for a in locator.appels)

    def test_plusieurs_cases_montent_sur_le_tapis(self) -> None:
        locator = FauxLocator(
            places=[self._place("285"), self._place("286"), self._place("295")]
        )
        bot = Bot(locator=locator, channel="lelio")
        reply = bot.answer(ChatMessage("a", "#lelio", "!card foret"), httpx.Client())
        assert reply is not None
        assert "À l'écran." in reply
        # La première correspondance porte la demande ; la base en déduit les
        # autres versions.
        assert "designate_strip:msh:285" in locator.appels

    def test_la_lecture_precede_l_ecriture(self) -> None:
        locator = FauxLocator(places=[self._place("285"), self._place("286")])
        bot = Bot(locator=locator, channel="lelio")
        bot.answer(ChatMessage("a", "#lelio", "!card foret"), httpx.Client())
        assert locator.appels.index("locate:foret") < locator.appels.index(
            "designate_strip:msh:285"
        )

    def test_un_refus_est_muet(self) -> None:
        # **Contrairement à `!montre`.** La réponse est déjà complète : `!card`
        # a dit où sont les cartes, le tapis n_était qu_un supplément. Annoncer
        # « écran occupé » là où personne n_attendait d_écran ajouterait du bruit.
        locator = FauxLocator(
            places=[self._place("285"), self._place("286")], accepte=False
        )
        bot = Bot(locator=locator, channel="lelio")
        reply = bot.answer(ChatMessage("a", "#lelio", "!card foret"), httpx.Client())
        assert reply is not None
        assert "écran" not in reply
        assert "Forêt" in reply

    def test_une_carte_absente_ne_touche_pas_a_l_ecran(self) -> None:
        locator = FauxLocator(places=[])
        bot = Bot(locator=locator, channel="lelio")
        reply = bot.answer(ChatMessage("a", "#lelio", "!card bidule"), httpx.Client())
        assert reply is not None
        assert "pas dans le classeur" in reply
        assert not any(a.startswith("designate_strip") for a in locator.appels)
