-- Un dépôt d'images pour les catalogues dont la source ne les sert pas.
--
-- **Première utilisation de Supabase Storage dans le projet**, et elle est une
-- exception assumée plutôt qu'une facilité. La règle de DeckHand est de ne
-- jamais réhéberger l'illustration d'une source (§IV.3 pour Scryfall, §IV.9
-- pour les sources sans conditions publiées) : on pointe l'URL de l'éditeur et
-- l'on n'en garde rien.
--
-- Wankul ne le permet pas. Son CDN rend `403 Hotlinking not allowed` — mesuré
-- sans `Referer`, avec un `Referer` étranger, et jusqu'avec celui de
-- `wankul.fr` : ce n'est pas un en-tête à ajuster, c'est une politique. Sans
-- dépôt intermédiaire, le classeur reste muet pour ce jeu seul.
--
-- **Ce qui autorise la copie, et rien d'autre :** LINK DIGITAL SPIRIT, éditeur
-- du jeu, l'a accordée nominativement, au même titre que la collecte du
-- catalogue (§IV.10). Le bucket n'est donc **pas** un cache générique où l'on
-- verserait les autres jeux au premier ennui de réseau : chaque jeu qui y
-- entrerait devrait apporter son propre accord. C'est pourquoi les objets sont
-- rangés sous un préfixe de jeu, et pourquoi ce commentaire existe.
--
-- **Le chemin n'est pas décoratif.** Il imite celui de Scryfall —
-- `.../normal/<id>.jpg` et `.../small/<id>.jpg` — parce que l'application sait
-- déjà passer de l'un à l'autre (`previewCardImage` échange le segment) pour
-- afficher une vignette légère avant la grande. Calquer la convention donne
-- les deux paliers sans une ligne de Dart à écrire ; s'en écarter aurait
-- demandé un cas particulier dans un module partagé par les cinq jeux.
--
-- `<id>` est l'`illustration_id` de l'impression, c'est-à-dire l'identifiant
-- que la source donne à son rendu. Il est déterministe : l'URL se calcule à
-- l'ingestion sans savoir ce que le bucket contient, et un versement partiel se
-- voit comme un 404, pas comme une base incohérente.

BEGIN;

-- `public = true` suffit à servir la route `/object/public/…` sans jeton : ce
-- chemin contourne la RLS de `storage.objects` par construction. Aucune
-- politique de lecture n'est donc déclarée — en ajouter une donnerait
-- l'illusion qu'elle garde quelque chose.
--
-- Les écritures, elles, restent hors de portée de `anon` et `authenticated` :
-- faute de politique d'écriture, la RLS les refuse toutes. Seule la clé de
-- service, qui la contourne, verse les images — et elle ne quitte pas le coffre.
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
    'card-art',
    'card-art',
    true,
    -- 2 Mio : le plus lourd des rendus Wankul pèse 300 Kio. Le plafond n'est pas
    -- une prévision de croissance, c'est un garde-fou contre le versement
    -- accidentel d'autre chose qu'une vignette.
    2097152,
    ARRAY['image/jpeg', 'image/png', 'image/webp']
)
ON CONFLICT (id) DO NOTHING;

COMMIT;
