"""Configuration de l'API, lue depuis le coffre de secrets hors dépôt.

Les secrets ne vivent jamais dans le dépôt : ils sont rangés dans
`../.deckhand-secrets/`, à la racine du conteneur de projets. Ce module est le seul
point qui connaît cet emplacement, surchargeable par la variable d'environnement
`DECKHAND_SECRETS` (utile en conteneur ou en CI, où le coffre est monté ailleurs).

Les variables d'environnement déjà présentes ont toujours priorité sur le fichier :
c'est ce qui permet à un déploiement d'injecter ses propres valeurs sans toucher au
disque.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

_DEFAULT_SECRETS_DIR = Path(__file__).resolve().parents[3] / ".deckhand-secrets"


class ConfigError(RuntimeError):
    """Configuration absente ou incomplète."""


def _secrets_dir() -> Path:
    return Path(os.environ.get("DECKHAND_SECRETS", _DEFAULT_SECRETS_DIR))


def load_env_file(name: str) -> dict[str, str]:
    """Lit un fichier `clé=valeur` du coffre de secrets.

    Les lignes vides et les commentaires sont ignorés. Un fichier absent renvoie un
    dictionnaire vide plutôt qu'une erreur : l'appelant décide si la valeur manquante
    est fatale.
    """
    path = _secrets_dir() / name
    if not path.is_file():
        return {}

    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        values[key.strip()] = value.strip()
    return values


def _require(values: dict[str, str], key: str, source: str) -> str:
    value = os.environ.get(key) or values.get(key)
    if not value:
        raise ConfigError(
            f"{key} introuvable — renseignez-le dans {_secrets_dir() / source} "
            f"ou dans l'environnement"
        )
    return value


@dataclass(frozen=True)
class SupabaseConfig:
    """Accès au projet Supabase.

    `db_url` pointe sur le *pooler* et non sur l'hôte direct : les projets Supabase
    récents n'exposent la connexion directe qu'en IPv6, injoignable depuis bien des
    réseaux. Le pooler reste accessible en IPv4.
    """

    url: str
    anon_key: str
    service_key: str
    db_url: str

    @classmethod
    def load(cls) -> SupabaseConfig:
        values = load_env_file("supabase.env")
        return cls(
            url=_require(values, "SUPABASE_URL", "supabase.env"),
            anon_key=_require(values, "SUPABASE_ANON_KEY", "supabase.env"),
            service_key=_require(values, "SUPABASE_SERVICE_KEY", "supabase.env"),
            db_url=_require(values, "SUPABASE_DB_URL", "supabase.env"),
        )


@dataclass(frozen=True)
class TopdeckConfig:
    """Accès à l'API TopDeck.gg.

    Rappel : toute utilisation de ces données impose d'afficher un crédit visible
    et un lien vers TopDeck.gg.
    """

    api_key: str

    @classmethod
    def load(cls) -> TopdeckConfig:
        values = load_env_file("topdeck.env")
        return cls(api_key=_require(values, "TOPDECK_API_KEY", "topdeck.env"))
