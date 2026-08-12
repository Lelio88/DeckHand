"""Résolution des noms de cartes des decklists vers le catalogue.

Les sources de decks nomment les cartes librement. TopDeck.gg emploie des
identifiants propriétaires qui ne sont pas des Scryfall IDs, il faut donc passer
par le nom — avec toute la variabilité que cela implique : casse, accents,
apostrophes typographiques, et cartes recto-verso écrites tantôt en entier
(« Delver of Secrets // Insectile Aberration ») tantôt par leur seule face avant.

**Les échecs sont comptabilisés, jamais avalés.** Un deck amputé de trois cartes
paraîtrait presque complet et fausserait tout le calcul de complétion — le pire
défaut possible pour ce produit. L'appelant peut donc consulter `unresolved`
et refuser un import trop lacunaire.
"""

from __future__ import annotations

from collections import Counter

from app.ingestion.scryfall_parse import normalize_name

# Séparateur des cartes à deux faces dans les exports de decklists.
_FACE_SEPARATOR = "//"


class CardResolver:
    """Traduit des noms de cartes en `oracle_id`, en tenant le compte des échecs.

    L'index est chargé une fois puis consulté en mémoire : à l'échelle du
    catalogue (quelques dizaines de milliers d'entrées), une requête par carte
    serait absurde alors qu'un dictionnaire suffit.
    """

    def __init__(self, index: dict[str, str]) -> None:
        # clé : nom normalisé — valeur : oracle_id
        self._index = index
        self._unresolved: Counter[str] = Counter()
        self._resolved_count = 0

    @property
    def unresolved(self) -> dict[str, int]:
        """Noms non résolus et leur nombre d'occurrences."""
        return dict(self._unresolved)

    @property
    def resolved_count(self) -> int:
        return self._resolved_count

    def resolve(self, name: str) -> str | None:
        """Renvoie l'`oracle_id` d'un nom de carte, ou None s'il est inconnu.

        Le nom complet est essayé en premier : « Fire // Ice » est une carte à
        part entière, la réduire à « Fire » désignerait une autre carte.
        """
        normalized = normalize_name(name)
        if not normalized:
            return None

        oracle_id = self._index.get(normalized)

        # Repli sur la face avant, pour les sources qui écrivent le nom complet
        # d'une carte que le catalogue indexe par sa seule face avant.
        if oracle_id is None and _FACE_SEPARATOR in normalized:
            front = normalize_name(normalized.split(_FACE_SEPARATOR)[0])
            oracle_id = self._index.get(front)

        if oracle_id is None:
            self._unresolved[normalized] += 1
            return None

        self._resolved_count += 1
        return oracle_id

    def resolve_deck(self, cards: dict[str, int]) -> tuple[dict[str, int], int]:
        """Résout une decklist entière.

        Renvoie les quantités par `oracle_id` et le nombre de cartes perdues.
        Les quantités sont cumulées quand deux orthographes désignent la même
        carte — un deck peut lister « Lightning Bolt » et « Foudre ».
        """
        resolved: dict[str, int] = {}
        missing = 0

        for name, quantity in cards.items():
            oracle_id = self.resolve(name)
            if oracle_id is None:
                missing += quantity
                continue
            resolved[oracle_id] = resolved.get(oracle_id, 0) + quantity

        return resolved, missing


class OracleResolver(CardResolver):
    """Variante pour les sources fournissant directement l'`oracle_id` Scryfall.

    MTGJSON est dans ce cas : plus de résolution par nom, donc plus d'ambiguïté
    de casse, d'accent ou de face. Il reste néanmoins une vérification à faire —
    le catalogue ne retient que les cartes légales dans les formats couverts, et
    insérer un identifiant absent violerait la clé étrangère, faisant échouer
    l'import entier.

    Hérite de `CardResolver` pour offrir la même interface : `store_deck` accepte
    les deux indifféremment.
    """

    def __init__(self, known_oracle_ids: set[str]) -> None:
        super().__init__({})
        self._known = known_oracle_ids

    def resolve(self, name: str) -> str | None:
        oracle_id = (name or "").strip()
        if not oracle_id or oracle_id not in self._known:
            if oracle_id:
                self._unresolved[oracle_id] += 1
            return None
        self._resolved_count += 1
        return oracle_id


class PrintCodeResolver(CardResolver):
    """Variante pour les sources désignant les cartes par leur **code
    d'impression** — extension et numéro de collection, `OGS-019`.

    C'est le cas des decklists Riftbound de TopDeck.gg, et c'est une chance : le
    couple (extension, numéro) désigne une case unique du catalogue. Plus
    d'ambiguïté de casse ni d'accent, et surtout plus de risque de confondre deux
    homonymes — Riftbound en compte quatre-vingts que seule l'illustration
    distingue, et qu'un rapprochement par nom rendrait indiscernables.

    **Le numéro est normalisé sur trois chiffres.** La source écrit `OGN-042`,
    le catalogue retient `42` : comparer les chaînes telles quelles échouerait
    sur toutes les cartes numérotées sous 100, soit la majorité. Un numéro non
    numérique — `SFD-171a`, une variante — est laissé tel quel et se résoudra ou
    non selon ce que porte le catalogue.

    Mesuré : 785 codes sur 786 se résolvent.
    """

    def __init__(self, index: dict[str, str]) -> None:
        super().__init__({})
        self._by_code = index

    @staticmethod
    def normalise(code: str) -> str:
        """`ogn-42` -> `OGN-042`. Rend le code tel que l'index le porte."""
        stripped = (code or "").strip().upper()
        set_code, separator, number = stripped.rpartition("-")
        if not separator or not number.isdigit():
            return stripped
        return f"{set_code}-{int(number):03d}"

    def resolve(self, name: str) -> str | None:
        code = self.normalise(name)
        oracle_id = self._by_code.get(code)
        if oracle_id is None:
            if code:
                self._unresolved[code] += 1
            return None
        self._resolved_count += 1
        return oracle_id


class PasscodeResolver(CardResolver):
    """Variante pour les sources désignant les cartes par leur **passcode** — le
    nombre à huit chiffres imprimé sur la carte elle-même.

    C'est le cas des decklists Yu-Gi-Oh de TopDeck.gg, et c'est le meilleur des
    trois cas possibles : le passcode est déjà l'identité dont le catalogue
    dérive ses `oracle_id`, il ne dépend d'aucune langue, et il n'a pas d'homonyme
    par construction. Mesuré sur les quatre formats retenus, il résout 99,94 %
    des citations. La résolution est donc un **calcul** et non une recherche : nul
    index de dizaines de milliers d'entrées à charger, seul l'ensemble des
    identités connues sert à vérifier que la carte existe bien au catalogue.

    **Le passcode cité n'est pas toujours celui du catalogue.** Une carte
    rééditée avec une nouvelle illustration reçoit un second passcode, voisin du
    premier — Monster Reborn est `83764719` au catalogue et `83764718` en
    illustration alternative — et les decklists cite l'un ou l'autre. Le
    catalogue ne retient que l'illustration principale : sans traduction, 21
    cartes restaient introuvables, dont Monster Reborn, Cyber Dragon et Foolish
    Burial. Ces cartes-là ne sont pas exotiques, elles sont partout : 97 decks
    sur 3 950 en portaient une, et 93 auraient été enregistrés **amputés** en
    passant sous le seuil de tolérance — donc annoncés plus complets qu'ils ne
    sont, ce que ce produit ne peut pas se permettre.

    D'où `aliases` : une table de traduction passcode -> `oracle_id`, construite
    par l'appelant pour les seuls passcodes que le calcul n'a pas su résoudre.
    """

    def __init__(
        self,
        known_oracle_ids: set[str],
        identity,
        aliases: dict[str, str] | None = None,
    ) -> None:
        super().__init__({})
        self._known = known_oracle_ids
        # Fonction passcode (int) -> identité de la carte. Injectée plutôt
        # qu'importée : c'est le catalogue du jeu qui définit l'identité de ses
        # cartes, ce module ne fait que s'en servir.
        self._identity = identity
        self._aliases = aliases or {}

    def resolve(self, name: str) -> str | None:
        """Le calcul fait autorité, la traduction n'est qu'un repli.

        L'ordre importe même si les deux ne peuvent en principe pas se
        contredire — la table n'est construite que sur les passcodes en échec.
        C'est précisément pourquoi le catalogue passe en premier : un alias
        erroné ne peut alors pas détourner une carte qui se résolvait bien.
        """
        code = (name or "").strip()
        if not code:
            return None

        oracle_id: str | None = None
        try:
            candidate = str(self._identity(int(code)))
        except (TypeError, ValueError):
            candidate = None
        if candidate is not None and candidate in self._known:
            oracle_id = candidate

        if oracle_id is None:
            oracle_id = self._aliases.get(code)

        if oracle_id is None:
            self._unresolved[code] += 1
            return None

        self._resolved_count += 1
        return oracle_id
