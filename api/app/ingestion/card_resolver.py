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
