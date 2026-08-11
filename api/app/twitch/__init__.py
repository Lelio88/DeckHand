"""Bot Twitch de DeckHand — en lecture seule.

Ce paquet fait tenir dans un chat la question « cette carte, je l'ai ? », et y
répond par une localisation plutôt que par un oui/non : `!card Ka-Zar` rend
l'extension, la page et la pochette. C'est le classeur-par-édition qui le
permet — une case étant `(set_code, collector_number)`, tout se calcule.

**L'écriture est écartée, pas oubliée.** Laisser des inconnus modifier une
collection ouvrirait la modération et l'abus comme sujets, pour un gain nul.

**Le bot ne voit rien de plus que la page publique.** Il s'adresse à Supabase
avec la clé anonyme et une adresse de partage ; c'est `binder_locate`, soumise
aux mêmes règles de ligne que la page, qui lui répond. La garantie ne vient donc
pas d'une prudence dans ce code : elle est dans la base, où un bot mal écrit ne
peut pas la contourner.

**Rien n'est déployé.** Le bot tourne sur le poste qui diffuse, à côté d'OBS,
le temps d'un direct :

    cd api && .venv/Scripts/python -m app.twitch

Découpage :

- `irc` — la connexion au chat, en TLS et sans dépendance
- `locator` — l'appel à `binder_locate`
- `reply` — la phrase rendue au chat, logique pure
- `throttle` — ce qui borne le débit, horloge injectable
- `bot` — la boucle qui relie les quatre
"""
