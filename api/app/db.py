"""Connexion Postgres qui survit à une coupure côté serveur.

**Pourquoi ce module existe.** Les connecteurs se protègent tous des coupures
*HTTP* — `limitless_ingest` réessaie six fois, attente doublée, avec ce
commentaire : « le réseau de ce poste coupe régulièrement, et une coupure ne
doit pas coûter la fenêtre entière ». Aucun ne se protégeait de la coupure
*base*, qui est pourtant le même risque et frappe la même connexion longue. Le
14 août à 00h10, Supabase a fermé les connexions ouvertes ; trois processus sont
morts ensemble, dont une ingestion à mi-fenêtre :

    psycopg.OperationalError: consuming input failed:
    server closed the connection unexpectedly

Elle avait couvert vingt jours sur trente. Les vingt étaient acquis — les
écritures commitées survivent — mais la course était à refaire depuis le début,
la pagination repartant toujours du plus récent.

**Ce que le module apporte, et ce qu'il exige en retour.** `Session.run` joue
une *unité de travail* ; si la connexion cède pendant, elle est fermée, une
neuve est ouverte, et l'unité est rejouée. En contrepartie :

1. **L'unité doit être idempotente.** Elle peut avoir écrit avant de céder ;
   rejouée, elle réécrira. Toutes les écritures d'ingestion le sont déjà, par
   `ON CONFLICT DO UPDATE` — c'est ce qui rend la reprise possible sans état.
2. **L'unité doit commiter ce qu'elle veut garder.** Ce qui n'est pas commité
   part avec la connexion morte, et la reprise ne peut pas le retrouver.
   L'unité de reprise et l'unité de commit sont donc le même découpage : un
   tournoi, un lot d'empreintes.

**Ce qui n'est pas rejoué, et c'est délibéré.** Seules les erreurs qui disent
« cette connexion n'existe plus » — `OperationalError`, `InterfaceError` — sont
traitées comme des coupures. Une `ProgrammingError` (colonne absente, SQL
fautif) remonte au premier coup : la rejouer cinq fois ne la corrigerait pas et
la ferait passer pour une instabilité réseau, ce qui est exactement le genre de
diagnostic qu'on paie ensuite en heures.

Exemple canonique — une boucle longue dont chaque tour est rejouable :

    with Session(config.db_url) as session:
        for tournoi in tournois:            # le réseau HTTP reste dehors :
            listes = telecharger(tournoi)   # inutile de le refaire à la reprise
            session.run(lambda conn: enregistrer(conn, listes))
        if session.recoveries:
            print(f"{session.recoveries} coupure(s) encaissée(s)")
"""

from __future__ import annotations

import time
from typing import Callable, TypeVar

import psycopg

T = TypeVar("T")

#: Erreurs qui signifient « cette connexion n'existe plus ». `OperationalError`
#: couvre la fermeture par le serveur et l'échec de connexion ; `InterfaceError`
#: est ce que psycopg lève quand on se sert d'une connexion déjà close.
LOST_CONNECTION = (psycopg.OperationalError, psycopg.InterfaceError)

#: Tours de reprise, attente doublée à chaque fois : 2, 4, 8, 16 s. Cinq tours
#: couvrent une minute et demie — assez pour un redémarrage de pooler, trop peu
#: pour qu'une base réellement éteinte immobilise la machine sans le dire.
ATTEMPTS = 5
FIRST_DELAY = 2.0

CONNECT_TIMEOUT = 60


class Session:
    """Une connexion Postgres, et de quoi la rétablir sans perdre la course.

    La connexion est ouverte à la première unité, puis réutilisée : la coupure
    est l'exception, pas le régime nominal.
    """

    def __init__(
        self,
        db_url: str,
        *,
        attempts: int = ATTEMPTS,
        first_delay: float = FIRST_DELAY,
        connect_timeout: int = CONNECT_TIMEOUT,
        connect: Callable[[], psycopg.Connection] | None = None,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        self._connect = connect or (
            lambda: psycopg.connect(db_url, connect_timeout=connect_timeout)
        )
        self._attempts = max(1, attempts)
        self._first_delay = first_delay
        self._sleep = sleep
        self._conn: psycopg.Connection | None = None
        #: Coupures encaissées depuis l'ouverture. Une ingestion qui n'en rend
        #: pas compte ferait passer une base instable pour une base saine.
        self.recoveries = 0

    def __enter__(self) -> "Session":
        return self

    def __exit__(self, *exc_info) -> None:
        self.close()

    def run(self, unit: Callable[[psycopg.Connection], T]) -> T:
        """Joue `unit`, la rejoue sur une connexion neuve si celle-ci a cédé.

        `unit` doit être idempotente et commiter ce qu'elle veut garder — voir
        l'en-tête du module.
        """
        delay = self._first_delay
        for attempt in range(self._attempts):
            try:
                return unit(self._ensure())
            except LOST_CONNECTION:
                # La connexion est morte : ni rollback ni commit ne passeront
                # dessus, elle n'est bonne qu'à être fermée.
                self._discard()
                if attempt == self._attempts - 1:
                    raise
                self.recoveries += 1
                self._sleep(delay)
                delay *= 2
        raise AssertionError("boucle de reprise sortie sans issue")  # pragma: no cover

    def close(self) -> None:
        """Ferme la connexion s'il y en a une. Sans effet sinon."""
        self._discard()

    def _ensure(self) -> psycopg.Connection:
        if self._conn is None:
            self._conn = self._connect()
        return self._conn

    def _discard(self) -> None:
        conn, self._conn = self._conn, None
        if conn is None:
            return
        try:
            conn.close()
        except Exception:
            # Fermer une connexion déjà morte lève selon la cause de la mort ;
            # l'objet est jeté de toute façon, l'échec n'apprend rien.
            pass
