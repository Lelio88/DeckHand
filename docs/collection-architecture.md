# Collection, classeurs et partage — DeckHand

Annexe de [`architecture.md`](./architecture.md). Ce qu'il advient d'une carte
une fois entrée : où elle se range, comment on retrouve son histoire, et à qui
on peut montrer le tout.

---

## 1. Ce que la collection sait d'elle-même

Une ligne de `collection_items` porte une carte, une impression, une finition et
une quantité. Trois choses en découlent, et chacune répond à une question
différente :

| Question | Ce qui répond |
|---|---|
| Qu'est-ce que je possède ? | `my_collection_summary` — exemplaires, références, valeur |
| Où est-ce rangé ? | Les classeurs (§2) |
| Quand est-ce entré ? | Le journal des mouvements (§3) |

**Préciser l'édition n'est jamais obligatoire** — la saisie rapide en dépend. Une
carte sans édition n'a donc aucune case, et vit dans la **pile à trier** jusqu'à
ce qu'on lui en donne une. La valorisation d'une collection qui en contient est
un **plancher**, pas une estimation, et l'interface le dit.

**Le compte de références dénombre les éditions**, c'est-à-dire les couples
(extension, numéro), là où le deckbuilding compte des cartes : 871 éditions de
Plaine partagent un `oracle_id` mais occupent 871 cases d'un classeur.

---

## 2. Les classeurs

### Le modèle : rien n'est stocké

**Un classeur est une édition, une case est le couple (extension, numéro).** Rien
de tout cela n'est une table : `my_binder_shelf` et `my_binder_page` dérivent
tout de `card_prints`. Une case n'est pas une impression — le catalogue porte
l'anglais et le français, et le #412 anglais partage sa case avec le #412
français. La langue est une propriété de ce qu'on range, pas de la case.

**Ce qu'un classeur montre et qu'une liste ne montre pas, ce sont les cases
vides** : la page part du catalogue, pas de la collection. Une case vide **dit
laquelle** — l'illustration manquante s'y affiche en fantôme à 24 %, sans requête
supplémentaire, le numéro restant par-dessus.

### Deux régimes de lecture

- Par **numéro**, le classeur range et montre les trous — « que me manque-t-il ».
- Par **valeur**, **exemplaires** ou **nom**, il inventorie, et les cases vides
  disparaissent : elles n'ont ni valeur ni place dans un ordre qui ignore les
  numéros.

Le filtre de finition, lui, **ne change pas de régime** : un classeur de
brillants garde ses trous, « je n'ai pas cette carte en brillant » restant une
complétion. Re-choisir un critère de tri **renverse** le classeur, et l'entrée du
menu annonce ce que le second appui fera.

`added_at` porte le **dernier** ajout et non la première acquisition : sans quoi
une carte qu'on possédait déjà et dont on ajoute un exemplaire restait
introuvable au milieu du classeur.

### L'étagère

L'entrée est une **étagère** des seules éditions où quelque chose est rangé — les
690 autres seraient vides. Chaque classeur s'y identifie **comme un produit** :
l'illustration de la carte-vedette de l'extension — la plus chère du set entier,
non de la collection — en bannière sous un voile sombre, coiffée du **symbole
officiel** du set.

Le symbole vient de la table `card_sets` et **non d'une URL déduite** : mesuré,
seules 32,7 % des extensions ont une icône homonyme, et la déduction échouait sur
deux classeurs sur cinq. Symboles et icônes sont **chargés depuis
`svgs.scryfall.io`, jamais embarqués** — ils sont copyright Wizards of the Coast,
et les commiter dans un dépôt public serait les redistribuer (garde-fou §IV.10).

### La feuille qui se tourne

Le relief vient de la **lumière** — reflet qui balaie la feuille, ombre portée sur
la page découverte, arête sombre à la reliure — et d'une courbure en **lamelles
composées de proche en proche**, chacune repartant du bord où la précédente
s'achève.

Le **dos d'une feuille montre des pochettes vides**, non la page suivante :
celle-ci est déjà visible dessous, et on croyait voir les cartes par-derrière.

Reliure à gauche, retour calculé en miroir, le doigt pilote l'avancement et lui
seul. Les pages sont **maintenues en vie trois minutes** : Riverpod les disposait
dès qu'une feuille quittait l'écran, ce qui annulait la requête en cours et
laissait certaines pages en chargement perpétuel.

### Couché, le classeur s'ouvre à plat

Deux faces côte à côte, reliure au milieu, et l'on avance de deux en deux. La
géométrie du retournement ne change pas — la feuille pivote toujours autour de
son bord gauche, mais ce bord tombe au milieu de l'écran. Elle **déborde sur la
moitié voisine** en se rabattant, et c'est ce qui fait qu'on la voit passer
par-dessus l'autre page.

**Le classeur se colle à droite, les commandes tiennent à gauche.** Deux pages
n'occupent que 1,43 fois leur hauteur quand un écran couché en fait 2,2 : le vide
latéral est acquis, et le centrer revenait à le partager en deux bandes
également inutiles. Rassemblé d'un côté, il devient une colonne où logent
l'entête et les réglages de lecture.

**Toute la hauteur va aux cartes** : barre du haut, navigation et barres du
système s'effacent. Mesuré sur l'appareil, la chrome consommait 290 des 408
points disponibles, laissant dix-huit cartes de quarante points perdues dans du
noir ; elles en font 92 une fois la place rendue. Le plafond est géométrique et
non perfectible — trois rangées de cartes réclament de la hauteur, et un écran
couché en manque.

C'est le seul écran qui autorise le paysage : l'application est verrouillée en
portrait, et le déverrouillage se demande à l'ouverture d'une page puis se rend
en la quittant.

### Une écriture rend ce qu'elle a fait

`set_collection_print` et `remove_from_collection` rendent le nombre **déplacé**
ou **retiré**, jamais un total — c'est ce qui les rend annulables. Le piège est
la **fusion** : déplacer vers une édition déjà possédée additionne, si bien qu'un
retour sans quantité emporterait aussi les exemplaires qui s'y trouvaient.

« Annuler » couvre les trois écritures qui font disparaître ce qu'on regarde :
retirer, corriger l'édition, ranger depuis la pile. Ajouter s'en passe, son
inverse étant le bouton juste en dessous. L'annulation s'exécute sur le
`ProviderContainer` et non sur `ref`, mort avec la feuille refermée.

---

## 3. Le journal des mouvements

`collection_movements` garde chaque entrée et chaque sortie, là où
`collection_items` n'a qu'une quantité et une date qu'un ajout écrase — « quand
ai-je acquis cette carte » n'avait aucune réponse.

**Écrit par trigger et non par les fonctions de mutation** : celles-ci sont
éprouvées, les rouvrir risquait une régression, et rien n'échappe au trigger.

**L'intention n'est pas stockée, elle se déduit.** Préciser une édition produit
deux mouvements opposés ; les lire comme une perte puis un achat ferait mentir le
journal. Un rangement se reconnaît à sa **signature** — exactement deux
mouvements de somme nulle sur une même carte dans une même transaction — plutôt
que d'être déclaré par l'appelant, qui pourrait mentir.

Le journal s'amorce sur un **report d'ouverture** daté de `added_at` : faux au
détail près, honnête à l'échelle, et son solde égale la collection dès le premier
jour. Il est inaltérable depuis le client — aucun droit d'écriture, le trigger
est `SECURITY DEFINER`.

**Une mesure ne doit rien laisser dans le journal.** `deck_math.py` sème une
partie d'un deck dans la collection puis se rétracte ; le trigger consignait ces
gestes, et quatre exécutions y avaient laissé 796 mouvements fantômes. Le harnais
relève donc où en est le journal avant d'écrire, puis efface ce qu'il y a ajouté
— deux fois, la suppression étant consignée à son tour.

---

## 4. Donner sa collection à lire

### La forme

`collections.is_public`, **faux par défaut**. Une politique publique sans drapeau
s'appliquerait à *toutes* les collections, y compris celles d'amis qui n'ont rien
demandé.

Ce qui devient lisible est ce qu'on possède et où c'est rangé. **`owner_id`,
non** : une collection publiée ne se rattache à aucun compte. L'adresse de
partage est l'identifiant de la **collection**, jamais celui de l'utilisateur.

### Ce qu'on donne, et sous quel nom

Un interrupteur seul publiait **tout** — les deux jeux et tous les classeurs. Ce
n'est presque jamais ce qu'on veut : on montre le classeur qu'on remplit, pas
l'inventaire complet. Deux colonnes portent ce que l'interrupteur ne pouvait pas
dire.

**`shared_sets text[]`, et `NULL` n'est pas `{}`.** `NULL` partage tout, y
compris les extensions à venir ; le tableau vide ne partage rien. Les aplatir en
un seul cas ouvrirait une collection entière par accident, et cocher les cinq
classeurs du jour figerait la liste — une extension ajoutée plus tard cesserait
d'être partagée sans que rien ne le dise. La portée est **une règle de la base**,
pas un filtre d'affichage : `collection_item_is_readable(collection, print)` la
consulte ligne par ligne, faute de quoi un visiteur curieux interrogerait la
collection directement et verrait tout.

**`slug`, facultatif.** Un UUID ne se dicte ni ne se retient ; un nom, oui.
Index unique **partiel** — deux collections privées peuvent rester sans nom, ce
qu'une contrainte d'unicité ordinaire n'aurait pas permis. `collection_by_handle`
accepte les deux formes, et ne rend rien pour une collection fermée : essayer des
noms au hasard ne doit pas révéler lesquels existent. L'identifiant continue de
fonctionner après qu'un nom a été pris, sans quoi les liens déjà donnés
mourraient.

### Trois refus de Postgres, et ce qu'ils apprennent

1. **`readable_collection` doit lire `owner_id` sans le rendre.** Elle répond à
   « quelle collection ai-je le droit de lire », ce qui suppose de comparer le
   propriétaire à l'appelant — précisément la colonne refusée à un inconnu. La
   fonction doit **consulter** la colonne, pas la **restituer** : c'est ce que
   dit `SECURITY DEFINER`.
2. **`SELECT 1 FROM collections` ne désigne aucune colonne**, et Postgres réclame
   alors le droit sur la table entière — les droits par colonne, l'outil précis
   pour « rien d'autre », n'y suffisent pas. Le besoin a été supprimé plutôt que
   la table ouverte : une fonction répond à la question, et les fonctions de
   classeur ne joignent plus `collections`.
3. **Quand plusieurs politiques s'appliquent, toutes sont évaluées** et leurs
   verdicts réunis par un OU. Les politiques de propriété visaient le rôle
   `public`, donc `anon` compris, et les évaluer demandait de lire `owner_id` :
   le refus tombait avant que la politique publique n'ait son mot à dire. Les
   restreindre à `authenticated` n'enlève aucun droit — un visiteur sans compte
   n'a pas de propriété à faire valoir.

### La page

**C'est le même classeur, pas une seconde vue.** Un provider unique,
`readCollectionProvider`, vaut `null` pour la sienne et un identifiant pour celle
d'un autre ; l'étagère comme les pages le lisent. Il dit ce qu'on demande, il
n'accorde rien — la base refuse une collection non publiée quel que soit le
chemin.

Trois choses n'ont pas de sens chez quelqu'un d'autre et disparaissent : la
**pile à trier** (elle compte les cartes du visiteur), la **recherche** (elle ne
connaît que sa collection, et ne trouverait rien tout en le laissant croire
vide), et la **feuille d'actions** sur une case — le toucher hérite alors de ce
que fait le maintien, agrandir, plutôt que de ne rien faire.

**Le vide ne s'explique pas.** Une collection non partagée rend la même étagère
qu'une collection sans carte : dire « celle-ci existe mais elle est privée »
confirmerait son existence à qui essaie des adresses au hasard.

L'**attribution** figure en pied de page. Le garde-fou §IV.2 tenait jusqu'ici par
un écran « à propos » qu'un visiteur n'ouvrira jamais.

### L'hébergement

Le build web est statique et GitHub Pages le sert
(`.github/workflows/pages.yml`). **Ce qui est publié n'est pas l'application** :
`DECKHAND_PUBLIC_ONLY` compile une variante qui ne sait que lire des classeurs
partagés — ni connexion, ni inscription. L'inscription est ouverte sur le projet
Supabase, et une adresse publique donnerait sinon à n'importe qui de quoi créer
un compte.

Les clés viennent des secrets d'actions, jamais du dépôt, et le résultat part en
artefact sans atterrir sur aucune branche. `--base-href` est obligatoire : un
site de projet est servi sous `/<dépôt>/`.

### Le bot de chat lit par la même porte

`api/app/twitch/` répond à `!card <nom>` dans un chat Twitch, en **lecture
seule**. Il tourne sur le poste qui diffuse, le temps d'un direct ; rien n'est
déployé.

**Il ne voit rien de plus que la page publique, et ce n'est pas une prudence de
son code.** Il s'adresse à Supabase avec la clé anonyme et une adresse de
partage ; `binder_locate` est `SECURITY INVOKER`, donc les règles de ligne qui
protègent la page le protègent par la même mécanique. En `SECURITY DEFINER`
elle deviendrait un chemin d'accès parallèle, et la portée choisie extension par
extension ne vaudrait plus rien pour qui connaît le nom de la collection.

**La réponse est une localisation, pas un oui/non** — extension, page, pochette.
Le rang d'une case parmi celles de son extension, divisé par neuf : rien n'est
stocké. L'ordre reproduit exactement celui de `my_binder_page` rangé par numéro,
faute de quoi le bot nommerait une page où la carte n'est pas.

**Trois silences, un seul message.** Carte absente, adresse inconnue, extension
retirée du partage : « pas dans le classeur ». C'est la même anti-énumération
que la page — et le débit épuisé se tait aussi, plutôt que d'annoncer qu'il
l'est, ce qui consommerait la ressource protégée.

Le crédit Scryfall est annoncé à la connexion, au plus une fois par demi-heure :
le garde-fou §IV.2 vaut pour un chat comme pour une page, mais une reconnexion
qui réannonce transforme le crédit en spam, et un spam se fait couper.

Mesuré : 220 noms possédés, **247 concordances contre `my_binder_page`, aucun
écart**. La première version en laissait 6 muets — `Merfolk`, `Alien`, `Hero`,
`Soldier`, `Wall`, `Leviathan` — tous des jetons, tous portés par plusieurs
cartes distinctes. Élire la meilleure correspondance et s'arrêter là répondait
« je ne l'ai pas » sur une carte rangée dans le classeur ; toutes les cartes du
meilleur score sont désormais retenues, et la possession tranche.

---

## 5. Impasses mesurées

À lire avant d'y revenir.

**Le fond du classeur.** Une grille réglée sur la seule largeur déborde en
paysage : la demi-largeur y est large et basse, et trois rangées de cartes
hautes n'y tiennent pas. La feuille se règle donc sur la plus contraignante des
deux dimensions.

**Le rapport figé.** Un rapport de 0,72 — la proportion d'une carte — coupait la
troisième rangée en portrait. Une feuille de classeur ne défile pas, elle se
tourne : c'est la grille qui s'adapte.

**Les lamelles pivotées de l'angle global** se croisaient et coupaient les cartes
en morceaux ; un `Stack` trop contraignant les dédoublait en escalier ; et **deux
angles pour une même facette** — le milieu pour pivoter, le bord pour avancer —
ouvraient entre elles des fentes par lesquelles on voyait la page du dessous à
travers une feuille pourtant opaque.

**Le classeur coté à l'extension entière.** `my_binder_page` appelait
`print_price` pour chaque impression du set et chaque finition — 1 732 appels
pour rendre neuf cases, soit 770 ms — avant de tout jeter sauf neuf lignes. La
fonction n'est pas inlinable par Postgres, son `SET search_path` en faisant une
boîte noire exécutée ligne à ligne. Les cases utiles étant connues d'avance, les
prix ne se calculent plus que pour elles : 126 à 167 ms, quelle que soit
l'extension.

**Les cartes en pleine taille pour une vignette.** Scryfall sert la même carte en
146 × 204 pour 14 Ko contre 99,6 Ko en 488 × 680 : une double page passait de 250
Ko à 1,8 Mo avant de vouloir dire quoi que ce soit. La vignette s'affiche donc
d'abord, la version nette se pose par-dessus.
