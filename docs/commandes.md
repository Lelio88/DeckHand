# Commandes — référence complète

Le `CLAUDE.md` ne garde que les commandes du quotidien. Tout le reste vit ici : les connecteurs d'ingestion jeu par jeu, les bancs de mesure, les outils de diagnostic de la reconnaissance, et les gestes d'administration de la base.

**Convention** : toutes les commandes se lancent depuis la racine du dépôt, le `cd` étant porté par la ligne. Les `--dart-define` de l'application sont obligatoires ; leurs valeurs vivent dans `../.deckhand-secrets/supabase.env`, jamais dans le dépôt.

## 1. Lancer et vérifier

```bash
# Les --dart-define sont OBLIGATOIRES (valeurs dans ../.deckhand-secrets/supabase.env)
cd app && flutter run -d chrome --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_PUBLISHABLE_KEY=...

cd app && flutter analyze && flutter test
cd api && .venv/Scripts/python -m pytest
```

## 2. Ingestion

Idempotente : une course saute ce qui n'a pas changé. `--force` reverse tout.

```bash
# Magic — catalogue, prix et decks
cd api && .venv/Scripts/python -m app.ingestion.refresh            # --force, --skip-decks

# Profils de decks — à relancer après toute écriture de decks OU de prix.
# Sans danger à lancer partout : il contrôle d'abord (30 ms) et ne reconstruit
# que s'il le faut (~2 min). `refresh` le fait en dernière étape ; pour un autre
# jeu, le lancer soi-même. Le banc §7 refuse de mesurer sur des profils périmés.
cd api && .venv/Scripts/python -m app.ingestion.deck_profile      # --force

# Riftbound
cd api && .venv/Scripts/python -m app.ingestion.riftcodex_ingest   # catalogue
cd api && .venv/Scripts/python -m app.ingestion.tcgcsv_prices      # prix (--force)
cd api && .venv/Scripts/python -m app.ingestion.topdeck_ingest --riftbound

# Yu-Gi-Oh
cd api && .venv/Scripts/python -m app.ingestion.ygoprodeck_ingest  # catalogue (--force)
cd api && .venv/Scripts/python -m app.ingestion.tcgcsv_yugioh_prices # prix (--force)
cd api && .venv/Scripts/python -m app.ingestion.topdeck_ingest --yugioh  # 4 formats rétro

# Pokémon
cd api && .venv/Scripts/python -m app.ingestion.tcgdex_ingest      # catalogue (--force)
cd api && .venv/Scripts/python -m app.ingestion.tcgcsv_pokemon_prices # prix (--force)
cd api && .venv/Scripts/python -m app.ingestion.limitless_ingest   # decks (--days N, défaut 90)
# Reprendre une course coupée : borne haute, pour ne pas repayer ce qui est acquis
cd api && .venv/Scripts/python -m app.ingestion.limitless_ingest --days 30 --before 2026-08-08

# Lorcana — seule source qui rend catalogue ET prix d'un seul tenant
cd api && .venv/Scripts/python -m app.ingestion.lorcast_ingest
cd api && .venv/Scripts/python -m app.ingestion.limitless_lorcana_ingest # decks (--days N)

# Star Wars Unlimited
cd api && .venv/Scripts/python -m app.ingestion.swu_ingest         # catalogue
cd api && .venv/Scripts/python -m app.ingestion.tcgcsv_swu_prices  # prix (--force)
cd api && .venv/Scripts/python -m app.ingestion.swumetastats_ingest # decks (--days N ; --skip N pour reprendre)

# One Piece
cd api && .venv/Scripts/python -m app.ingestion.optcg_ingest       # catalogue
cd api && .venv/Scripts/python -m app.ingestion.tcgcsv_onepiece_prices # prix (--force)
cd api && .venv/Scripts/python -m app.ingestion.limitless_onepiece_ingest # decks (--days N)

# Wankul — sous autorisation nominative ; la source refuse le téléchargement d'illustrations
cd api && .venv/Scripts/python -m app.ingestion.wankul_ingest      # catalogue (958 cartes, ~2 min)
# Vignettes vers le bucket card-art (--force pour reverser) — à jouer AVANT l'ingestion
cd api && .venv/Scripts/python -m app.ingestion.wankul_art_upload <dossier>
# Index d'empreintes depuis un dossier local
cd api && .venv/Scripts/python -m app.vision.local_index wankul <dossier>
```

## 3. Bot Twitch et calque de direct

```bash
# Lecture seule — tourne le temps d'un direct, rien à déployer
# Six commandes ; trois atteignent l'écran (*) : !card* <nom> · !page* <ext> <n>
# · !montre* <nom> · !dernieres · !classeur · !deckhand
cd api && .venv/Scripts/python -m app.twitch                       # --game riftbound
# Le même bot, lié à Streamlabs : démarre avec lui, s'arrête quand on le ferme,
# relancé trois fois au plus s'il tombe. -Verifier contrôle sans rien lancer ;
# -Raccourci pose « Direct DeckHand » sur le bureau.
pwsh -File tools/direct/lancer-direct.ps1                          # -Verifier · -Raccourci

# Le dos des cartes que feuillette le calque, versé dans le bucket card-art et
# relu avec l'Origin du calque (CORS). Seuls les jeux dont la table du module
# cite l'accord écrit de la source sont acceptés ; --file pour un dos remis
# hors ligne par un éditeur.
cd api && .venv/Scripts/python -m app.ingestion.card_back_upload   # tous · <jeu> · <jeu> --file <chemin>
# Un dos scanné d'une carte possédée : rien n'est réhébergé, la table n'a donc
# pas à donner son accord — mais le fichier reste contrôlé (JPEG debout, rapport du jeu).
cd api && .venv/Scripts/python -m app.ingestion.card_back_upload <jeu> --file <chemin> --scan

# L'animation de `!montre`, sans base ni compte — le widget de production
cd app && flutter run -d chrome -t tool/apercu_montre.dart
# Le même mouvement, figé : huit images du feuilletage et de la sortie, hors dépôt
cd app && DECKHAND_FONTS=<flutter>/bin/cache/artifacts/material_fonts \
    flutter test test/apercu_montre_test.dart --update-goldens
# Ce que coûte une image du calque : widgets (stable) et pump (variable)
cd app && DECKHAND_BENCH=1 flutter test test/bench_montre_test.dart
# Le froissement des pages, en .wav — trois voix, la seule façon d'en juger
cd app && DECKHAND_BENCH=1 flutter test test/ecoute_son_test.dart
# L'intro : cinq images de la distribution, pour la regarder au lieu de la deviner
cd app && DECKHAND_FONTS=<flutter>/bin/cache/artifacts/material_fonts \
    flutter test test/apercu_intro_test.dart --update-goldens
# Le jingle, régénéré à l'identique (six notes, sol mixolydien)
cd api && .venv/Scripts/python ../tools/sounds/gen_intro_jingle.py
```

## 4. Reconnaissance — cadrage et détection

```bash
# Ce qui tue l'empreinte sur un flux : résolution, flou, inclinaison, éclairage
cd app && dart run tool/flux_bench.dart <carte.jpg> --game magic
# Une carte remplit sa boîte, un amas non : où poser le seuil
cd app && dart run tool/fill_bench.dart tool/.framing_cache
cd app && dart run tool/frame_bench.dart   # durées réelles : --dart-define=DECKHAND_BENCH=true
# Détection de bords : 40 cartes × 8 régimes de cadrage et d'éclairage
cd api && .venv/Scripts/python -m app.measure.export_framing_set   # une fois, hors dépôt
cd app && dart run tool/framing_bench.dart              # --centered pour comparer
cd app && dart run tool/probe_photo.dart <photo> --game riftbound --out <dossier>

# Détection par droites : trouvées d'un côté, INVENTÉES de l'autre
cd app && dart run tool/hough_bench.dart <dossier de photos>   # --sans-carte, --dump <dir>, --balayage
cd app && dart run tool/hough_probe.dart <photo> <dossier>     # bords retenus, droites dominantes
cd app && dart run tool/hough_time.dart <dossier de photos>    # coût par image, contre la production
# Où le contour se perd : droite absente, appariement refusé, ou garde-fou aval ?
cd app && dart run tool/assemblage.dart          # --photo <fichier> pour une seule

# Flux : détecter à chaque image, ou suivre le quadrilatère
cd app && dart run tool/stream_bench.dart   # --cards N --regime <nom> --noise N
# VOD de pack opening : ffmpeg + le pipeline de production, sans portage
cd app && dart run tool/vod.dart <video> --game magic   # --fps 1 --accord 2
cd app && dart run tool/vod.dart <dossier> --images     # sans vidéo : critère zéro carte
```

## 5. Reconnaissance — plafond et empreintes

Le banc de photos réelles vit **hors dépôt**, dans `../../.deckhand-bench/` (voir son README).

```bash
cd app && dart run tool/recette.dart --dump <dossier>   # carte seule : trouvées, douteuses
cd app && dart run tool/etalement_bench.dart --dump <dossier>  # étalement : manquées, en trop
cd app && dart run tool/planche.dart <dossier> <sortie> # planche contact, pour annoter à l'œil

# Le cadre est-il faux, ou la carte muette ? Deux moitiés d'une même mesure.
cd app && dart run tool/plafond.dart <dossier de photos> --out tool/.cache/plafond.json
cd api && .venv/Scripts/python -m app.measure.plafond_empreinte --parite   # FFT contre balayage
cd api && .venv/Scripts/python -m app.measure.plafond_empreinte --temoin   # rendu officiel : 0 bit ?
cd api && .venv/Scripts/python -m app.measure.plafond_empreinte --dump <dossier>  # tracer les cadres
cd api && .venv/Scripts/python -m app.measure.plafond_empreinte --depuis .cache/plafond-mesure.json
# Balayer un seuil de détection — juge sur l'identification, jamais sur le détourage
cd app && dart run tool/plafond.dart <dossier> --rupture 0.20 --support 0.74

# Ce que l'app reconnaît VRAIMENT — sur l'appareil, OCR compris (seule mesure entière)
cd app && adb push <photos>/. /sdcard/Android/data/app.deckhand.debug/files/
cd app && flutter test integration_test/plafond_reel_test.dart -d <appareil> \
    --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_PUBLISHABLE_KEY=... \
    --dart-define=DECKHAND_TEST_EMAIL=... --dart-define=DECKHAND_TEST_PASSWORD=...
cd api && .venv/Scripts/python -m app.measure.plafond_reel <journal.log>

# Ce que l'index annonce quand il ne devrait rien dire — à rejouer à chaque jeu
cd api && .venv/Scripts/python -m app.measure.art_collisions        # --game <jeu> --sample N
# Où tombe, dans l'index réel, une empreinte relevée sur le terrain (`art_hash` du journal)
cd api && .venv/Scripts/python -m app.measure.art_probe <hex> --game riftbound --expect "<carte>"
```

## 6. Bancs par jeu

Un jeu accueilli se mesure avant d'être ingéré : périmètre, identité, gabarits d'illustration. Voir [`multi-game.md`](./multi-game.md).

```bash
cd api && .venv/Scripts/python -m app.measure.lorcana_taxonomy     # périmètre, identité, maquettes, prix
cd api && .venv/Scripts/python -m app.measure.lorcana_art_window   # --compare / --dump
cd api && .venv/Scripts/python -m app.measure.onepiece_taxonomy    # périmètre, identité, homonymes
cd api && .venv/Scripts/python -m app.measure.onepiece_art_window  # --size N --group T --dump DIR --compare
cd api && .venv/Scripts/python -m app.measure.onepiece_decks       # ce que Limitless publie du jeu
cd api && .venv/Scripts/python -m app.measure.swu_taxonomy         # périmètre, identité, orientation, finitions
cd api && .venv/Scripts/python -m app.measure.swu_decks            # --days N --limit N : gabarit, résolution, aspects
cd api && .venv/Scripts/python -m app.measure.swu_art_window       # --size N --group G --dump DIR
cd api && .venv/Scripts/python -m app.measure.pokemon_taxonomy     # familles et discriminants
cd api && .venv/Scripts/python -m app.measure.pokemon_art_window   # --group / --merge / --dump
cd api && .venv/Scripts/python -m app.measure.pokemon_energy_collisions
cd api && .venv/Scripts/python -m app.measure.wankul_art_window <dossier> # --terrains / --verticales
```

## 7. Produit, données et écran

```bash
# Arithmétique de l'écran Decks
cd api && .venv/Scripts/python -m app.measure.deck_math constructed riftbound
# De quoi un deck est fait — traits et zones propres à chaque jeu
cd api && .venv/Scripts/python -m app.measure.deck_anatomy --game yugioh
# Le trait d'union coûte-t-il des recherches ? — exposition, puis pertes réelles
cd api && .venv/Scripts/python -m app.measure.nom_trait_union --game yugioh
# Pourquoi le scan rendait « statement timeout » : le prix, joint catalogue entier
cd api && .venv/Scripts/python -m app.measure.price_join            # --noms 10 50 150
cd api && .venv/Scripts/python -m app.measure.price_join --cartes 1 8 16 24
# L'onglet Decks tient-il dans les 8 s du rôle ? — un format par jeu, sort 1 si non
cd api && .venv/Scripts/python -m app.measure.deck_suggestions      # --game magic
# Regarder une tuile plutôt que la deviner — une capture par chiffre, hors dépôt
cd app && DECKHAND_FONTS=<flutter>/bin/cache/artifacts/material_fonts \
    flutter test test/apercu_tuiles_test.dart --update-goldens
```

## 8. Base de données et configuration

Une politique se vérifie **dans les deux sens** et **sous le rôle qui la subit** : le cas permis prouve qu'elle marche, le cas refusé qu'elle sert. La connexion d'ingestion est propriétaire et masque les oublis de `GRANT` comme de RLS.

```bash
# Politique RLS d'une table, éprouvée sous le rôle qui la subit
cd api && .venv/Scripts/python -m app.measure.profiles_rls
# La désignation : la seule écriture ouverte à `anon`, et ses cinq refus
cd api && .venv/Scripts/python -m app.measure.spotlight_rls

# Migrations — jouées par psycopg, le CLI Supabase exigeant un lien interactif
cd api && .venv/Scripts/python apply_migration.py ../supabase/migrations/<fichier>.sql

# Config d'authentification : relais d'envoi, adresses de retour, gabarits
cd api && .venv/Scripts/python push_auth_config.py             # --verifier pour lire
```
