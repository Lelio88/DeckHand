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

### Les chiffres que la page de profil sait dire

`my_collection_summary` rend sept colonnes, dont la page tire **deux séries
défilantes** — une pression, ou un glissement latéral, passe à la suivante :

| Série | Ce qu'elle enchaîne |
|---|---|
| Contenu | exemplaires → références → extensions entamées → boosters équivalents → complétion au mieux |
| Valeur | totale → une de chaque → moyenne par carte → en boosters achetés → carte la plus chère |

Les afficher toutes tiendrait de l'inventaire : six nombres sur une page de
profil ne se lisent plus. Un seul est montré, et une **jauge de segments** dit
que les autres existent — sans elle, personne ne penserait à appuyer. Le segment
actif est plus long en plus d'être plus vif : un indicateur de position qui ne
tient qu'à une teinte n'en est pas un.

**Le label dit ce qu'on regarde, l'unité rejoint le nombre.** Écrire « euros »
sous chacun des cinq chiffres de valeur gaspillait la seule ligne capable de les
distinguer : ils s'annonçaient tous pareil, et l'on pouvait ouvrir la page sans
savoir ce que comptait le dernier. Le symbole est donc accolé au nombre —
« 15,49 € », espace insécable comprise, sans quoi le chiffre principal se lirait
en escalier sur une demi-largeur d'écran — et le label porte le sens : « au
total », « sans doublons », « dépensé », « la plus chère ».

**Le glissement va dans les deux sens**, à la convention des galeries : le doigt
pousse le contenu, donc vers la gauche pour avancer, vers la droite pour revenir.
Il n'avançait que d'un cran quel que soit le sens, ce qui demandait sept gestes
pour revenir d'un chiffre.

**Deux lignes de légende sont réservées, occupées ou non.** Les légendes vont
d'un mot à une phrase ; sans plancher, la tuile changeait de hauteur à chaque
pression et la page tressautait sous le doigt. Un minimum, et non une hauteur
fixe : une police système agrandie doit pouvoir le déborder sans peindre une
bande d'erreur.

**« Une de chaque » se compte par référence**, au sens de `distinct_cards`, et
retient la plus chère des finitions d'une même case : c'est celle qu'on
garderait.

**Un seul de ces chiffres désigne une action** : la complétion au mieux —
« Marvel Super Heroes, 234/453 ». Les autres décrivent ; celui-ci dit où aller,
puisque finir un classeur déjà bien avancé coûte moins cher que d'en ouvrir un
neuf. Aucune taille minimale n'est imposée en revanche — ce serait un seuil
inventé, et s'il faut en poser un, c'est une mesure qui l'établira.

**Les extensions de jetons sont écartées des deux chiffres d'extension** — le
compte comme la complétion. Dix fois plus petites qu'une extension de boosters
(27 cartes pour `tmsh` contre 453 pour `msh`), elles gagneraient mécaniquement la
complétion, pour des cartes dont aucune n'est jouable en construit ; et une même
sortie produisant jusqu'à quatre extensions — boosters, decks Commander, jetons
de chacune —, le compte annonçait « six extensions » à qui a ouvert deux boîtes.
Le nombre était exact et la réponse fausse : personne ne collectionne un jeu de
jetons. **L'écran le dit** — « entamées, hors jetons » — parce qu'un total qui
exclut quelque chose sans le dire se lit comme un bug.

**Le taux n'est pas calculé en base**, seulement ses deux termes : décider des
décimales et du sens d'une division par zéro n'a rien à faire en SQL.

**La moyenne par carte ne coûte rien** — c'est une division entre deux chiffres
déjà reçus. Elle distingue ce qu'aucun total ne distingue : mille communes et
dix rares peuvent valoir la même chose.

**Les deux chiffres en boosters ne se déduisent d'aucune donnée** : ils exigent
de savoir ce qu'un booster contient et ce qu'il coûte, et **aucun des deux
nombres n'existe au singulier**.

La première version de `booster_size.dart` tenait la **taille** pour un fait
publié, stable et identique pour tous, donc inscrite dans le code « pour de
bon ». C'est faux dès qu'on regarde un rayon : un même jeu vend plusieurs
produits à des contenus différents — Play Booster à 14 cartes, Collector à 15,
Set à 12 chez Magic — et le commentaire de `onepiece` l'admettait déjà sans en
tirer la conséquence, « les boosters japonais font 6 à 9 cartes ; c'est le format
français qui est retenu ». Retenir un format, c'est choisir pour quelqu'un
d'autre. La taille est donc **une préférence du compte**
(`profiles.booster_sizes`), et ce qui reste dans le code est un repère : les huit
jeux y figurent, de 9 cartes chez Yu-Gi-Oh à 16 chez Star Wars Unlimited. **Un
jeu absent de cette table n'affiche pas ces chiffres** plutôt que d'en inventer.

Le **prix**, lui, n'existe pas au singulier. Relevé le 24 août 2026, même
produit, même jour : un booster Pokémon Méga-Évolution vaut **4,99 €** chez
Micromania et **9,90 €** chez Play-in ; un Play Booster Magic revient à
**5,29 €** acheté par display et **7,40 €** à l'unité. Près du double d'écart. Un
prix inscrit dans le code serait donc faux pour à peu près tout le monde, et faux
**sans le dire** — et l'indicateur répond justement à « combien **j'aurais**
dépensé ». Le prix est donc lui aussi **une préférence du compte**
(`profiles.booster_prices`, un `jsonb` indexé par jeu, comme les tailles),
réglable depuis la ligne même qui l'affiche ; ce qui reste dans le code n'est
qu'un **repère daté et sourcé**, appliqué tant que l'utilisateur n'a rien dit.

**Les deux réglages tiennent dans une seule boîte, et partent en une seule
écriture.** Ils décrivent un même objet — le produit qu'on achète : les séparer
obligerait à ouvrir deux fois pour déclarer « j'ouvre des Collector Boosters à 15
cartes, payés 22 € », qui est une seule décision, et deux `upsert` successifs
laisseraient une fenêtre où la taille est enregistrée et le prix non — le temps
de laquelle l'indicateur afficherait une dépense calculée sur un produit et payée
sur un autre. Les deux lignes qui en dépendent, une par tuile, ouvrent la même
boîte.

**Trois états, comme pour les jeux joués.** Clef absente = « je n'ai rien
déclaré », et le repère s'applique. Zéro = « je n'achète pas de boosters », et
l'indicateur affiche zéro euro. Vider le champ **écrit** le retour au repère,
plutôt que de ne rien écrire — sans quoi on n'y reviendrait qu'en retapant le
repère de mémoire.

**Zéro n'est une réponse que pour le prix.** Un booster à zéro carte ne décrit
aucun produit, et diviserait par zéro les deux indicateurs qui s'en servent : la
saisie le refuse, la lecture Dart l'écarte, et une contrainte le refuse en base —
le seul des trois qu'un client tiers ne peut pas contourner. Elle passe par une
fonction `IMMUTABLE`, `booster_sizes_are_positive` : parcourir un `jsonb` demande
`jsonb_each`, qui rend un ensemble, et Postgres refuse une sous-requête dans un
`CHECK`.

**Deux pièges de performance, tous deux invisibles depuis la connexion
d'ingestion.**

*L'index manquant.* `card_prints` ne portait aucun index sur `set_code`, si bien
que compter les cases d'une extension balayait ses 245 468 lignes. Mesuré sous
`authenticated` : **7,85 s à froid**, quand le rôle coupe à 8 s — la fonction
passait en répétant la mesure et serait tombée au premier appel après un
redémarrage. `idx_card_prints_set (set_code, collector_number)` ramène la même
requête de **287 ms à 16 ms** à chaud, et le profil de 7,85 s à 2,92 s à froid.
`my_binder_shelf` fait exactement ce calcul depuis toujours pour le taux de
complétion de chaque classeur : l'étagère profite du même index.

*L'inlining des CTE.* La première version de la fonction dépassait
le `statement_timeout` de huit secondes du rôle `authenticated` : depuis
PostgreSQL 12, une `WITH` sans effet de bord est *inlinée*, si bien que les trois
lectures des prix les recalculaient trois fois. `MATERIALIZED` rétablit ce que
l'on croyait écrire. Mesuré **sous le rôle réel** — la connexion d'ingestion est
propriétaire et ne porte pas ce délai, elle aurait montré une fonction
parfaitement saine.

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

### Ce que tourner une page coûtait

Les feuilles voisines étaient préchargées, mais **seulement leurs données** :
3,5 Kio, 57 à 78 ms mesurés sous `authenticated` — ce n'est pas ce qu'on
attendait. `page_turn.dart` ne construit la feuille suivante qu'à l'intérieur de
son `AnimatedBuilder`, c'est-à-dire **une fois le geste commencé** : au repos,
`_atRest` ne bâtit que la feuille courante. Les neuf images de la suivante
partaient donc à l'instant précis où l'on tirait la feuille, et celle-ci se
découvrait vide.

Les **vignettes** des feuilles voisines sont désormais demandées dès que leurs
données arrivent — 126 Ko par feuille, contre 900 Ko si l'on préchargeait les
grandes, ce qui ferait près de deux mégaoctets par déplacement. Les grandes
continuent d'arriver derrière, comme sur la feuille courante : c'est la
stratégie qui existait déjà, appliquée une feuille plus tôt.

**L'ouverture d'un classeur, elle, n'a jamais été le problème** : un seul appel,
78 ms, et l'étagère est déjà chargée.

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

#### Une sortie, plusieurs classeurs — groupés, jamais fusionnés

**Une sortie ne produit pas une extension mais une famille.** « Marvel Super Heroes » en compte quatre : les boosters (`msh`, 453 cartes), les decks Commander (`msc`, 866), et un jeu de jetons pour chacune (`tmsh` 27, `tmsc` 32). L'étagère les alignait au même niveau — cinq classeurs en vrac pour une seule sortie — alors que `card_sets.parent_set_code` porte la parenté depuis l'ingestion et n'était **lu nulle part**, ni en SQL ni en Dart.

**Le regroupement ne fusionne rien, et c'est la mesure qui l'interdit.** Chaque extension a sa propre numérotation, et les numéros se chevauchent : le n° 1 vaut « Agent 13, Sharon Carter » dans `msh`, « Invisible Woman » dans `msc` et « Wall » dans `tmsh`. Trois cartes ne tiennent pas dans une case — c'est exactement pourquoi l'édition se lit par son code et jamais par son numéro. Chaque extension garde donc son classeur ; seule sa place sur l'étagère change.

`groupIntoFamilies` remonte la chaîne de parenté jusqu'à la **racine possédée** — `tmsc` → `msc` → `msh`, deux niveaux — et s'arrête au dernier maillon présent : on peut posséder des jetons sans avoir ouvert un booster, et les rattacher à une mère absente les ferait disparaître. Une parenté circulaire rend chaque extension à elle-même plutôt que de désigner une tête introuvable, ce qu'un test a imposé en faisant planter l'écran.

**Les jetons se rangent en dernier et se signalent.** Aucune de leurs cartes n'est légale en Pauper, Modern ni Commander — vérifié sur la collection réelle, zéro sur vingt-deux exemplaires. Ils passent donc derrière les satellites jouables quel que soit leur remplissage, et portent une pastille : rien d'autre ne les distingue, ni la bannière, ni l'illustration, ni le taux de complétion.

**Deux réglages viennent de l'appareil et non du raisonnement.** La tuile satellite fait 100 px et non 92 : à 92, le pourcentage remontait sous le symbole d'extension. Et un satellite n'affiche plus ce symbole — il est celui de sa mère, juste au-dessus — ce qui libère le coin haut-droit pour la pastille, laquelle chevauchait le titre.

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

`api/app/twitch/` répond dans un chat Twitch. Il tourne sur le poste qui diffuse,
le temps d'un direct ; rien n'est déployé. Cinq commandes lisent, une écrit.

| commande | ce qu'elle dit | ce qu'elle appelle |
|---|---|---|
| `!card <nom>` | la carte est-elle possédée, où, et ce qu'elle vaut | `binder_locate` |
| `!montre <nom>` | fait monter la carte sur l'overlay | `binder_locate` puis `public_request_spotlight` |
| `!page <ext> <n>` | ce qui manque à une page | `public_binder_page` |
| `!dernieres` | les trois dernières cartes entrées au classeur | `public_recent_additions` |
| `!classeur` | l'avancement, extension par extension | `public_binder_shelf` |
| `!deckhand` | l'adresse du classeur et le crédit | rien |

**`!page` est « qu'est-ce qui te manque » ramené à une échelle où la question a
une réponse.** Sur une extension entière il manque des centaines de cases — 219
sur Marvel Super Heroes — et aucune troncature n'en fait une phrase utile ; une
page en compte neuf au plus, et ses vides se nomment tous par leur numéro. C'est
pourquoi `!manque <extension>` a été écartée, et pas celle-ci.

**`!card` rend désormais la cote**, prise sur la case à la finition possédée.
Elle vient de `binder_locate` elle-même : un second appel à `print_price`
partirait sur **chaque** réponse réussie, là où le repli sur le trait d'union ne
part que sur un échec. Une impression sans cote n'affiche **rien** plutôt que
« 0,00 € » — Scryfall ne cote pratiquement que l'anglais, et l'absence de prix
n'est pas une absence de valeur.

**`!dernieres` est celle que le direct rend possible.** Un spectateur qui arrive
en cours de route rattrape en une ligne ce qui vient d'être ouvert — et cela n'a
de sens que parce que les cartes sont scannées au fur et à mesure. Aucun bot de
collection générique ne peut la servir.

**Une fonction publique n'est pas une fonction accordée à `anon`.** `my_binder_
shelf` l'est, et ne rend pourtant rien au bot : elle filtre sur `auth.uid()`,
nul sous la clé anonyme. Trois fonctions seulement acceptent une **adresse de
partage**, et ce sont les seules que le bot puisse appeler — d'où
`public_binder_shelf`, écrite pour lui et calquée sur `binder_locate`. Le droit
d'exécution ne dit rien de ce qu'une fonction accepte en argument ; c'est la
signature qui décide.

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

**Un second essai quand le premier ne rend rien**, traits d'union et espaces
échangés. `!card ka zar` répondait « pas dans le classeur » alors que *Ka-Zar*
y est — une réponse fausse, pas une absence de réponse. La cause n'est pas la
normalisation : mesuré, un **nom complet** mal saisi est retrouvé dans 100 % des
cas (2 111 noms Magic, zéro perdu, autant dans l'autre sens). Le défaut ne vit
que sur un **fragment**, où la similarité trigramme s'effondre — « ka-zar »
contre « ka-zar of the savage land » vaut 0,27 quand le seuil est à 0,30 — et où
il ne reste que la branche préfixe, un `LIKE` littéral. Coût : 21 cartes en
Magic, 32 en Yu-Gi-Oh, **zéro** en Lorcana et Riftbound, dont le trait d'union
sépare deux mots au lieu d'en lier un. Le repli ne part que sur un échec, et le
débit est vérifié avant l'appel réseau : il ne peut pas déborder le plafond.
`normalize_card_name` n'est pas touchée, ni son jumeau Dart.

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

## L'overlay OBS — ce que le direct montre (#14)

DeckHand ne touche jamais la vidéo. OBS filme ; DeckHand publie ce qu'il a vu ;
une *browser source* le lit à l'adresse `?o=<adresse-de-partage>`. C'est la même
porte publique que le classeur, avec une autre page derrière.

### La source de l'événement est le journal, pas le flux

L'issue faisait dépendre l'overlay du mode temps réel (#8). **Ce n'était pas
nécessaire** : le journal des mouvements existe déjà, et une carte qui entre en
collection est exactement une carte reconnue puis confirmée. Le garde-fou §IV.8
s'en trouve respecté sans effort — rien n'est publié en direct que l'utilisateur
n'ait validé.

### Le piège : un journal contourne les choix de partage

`shared_sets` permet de ne publier que certaines extensions. Un journal lu sans
ce filtre montrerait en direct des cartes que le classeur public, lui, cache — et
personne ne s'en apercevrait, les deux écrans étant distincts.

Le filtre vit donc dans `public_recent_additions`, en base, et non dans la page.
Vérifié dans les quatre sens, sur la collection réelle, dans une transaction
annulée :

| Cas | Attendu | Mesuré |
|---|---|---|
| Collection non publiée | rien | 0 ligne |
| Adresse inconnue | rien | 0 ligne |
| Publiée, portée complète | tout | 50 lignes |
| Publiée, deux extensions sur cinq | ces deux-là | 50 → 17, aucune hors portée |
| Carte sans édition, portée restreinte | disparaît | 1 → 0 |

Le dernier cas n'existait pas dans les données : un mouvement sans impression a
été créé dans la transaction annulée, sans quoi le test aurait été vide — et un
test vide se lit comme un test réussi.

### Une interrogation périodique plutôt que Realtime

L'issue supposait `postgres_changes`. Deux raisons de ne pas le prendre, et la
seconde vient de l'issue elle-même.

- **La portée.** Diffuser les lignes brutes du journal demanderait d'ouvrir
  `collection_movements` à `anon`, donc de réécrire la règle `shared_sets` dans
  une politique — un second endroit où l'oublier.
- **La robustesse.** L'overlay doit « résister à la coupure réseau sans afficher
  d'erreur en plein direct ». Une interrogation qui échoue est **sans effet** :
  la carte affichée reste. Une connexion persistante coupée demande une
  reconnexion, donc du code qui peut échouer au pire moment.

Cadence : une seconde et demie. Un direct de deux heures fait cinq mille
requêtes, le prix d'une page qui se recharge, étalé.

### Trois pièges, trois tests

- **Rien au démarrage.** La dernière carte du journal peut dater de la veille ;
  l'afficher au lancement d'OBS ferait croire qu'on vient de l'ouvrir. La
  première réponse ne fait qu'établir la référence.
- **L'identifiant de mouvement, pas le nom.** Deux exemplaires successifs de la
  même carte sont deux événements — et le second est le plus intéressant,
  puisqu'il fait le doublon. Une comparaison par nom l'avalerait.
- **L'effacement a besoin de son propre réveil.** Une première version comparait
  l'heure courante dans `build` ; rien ne provoquant de reconstruction à
  l'échéance, la carte serait restée jusqu'à l'arrivée de la suivante,
  c'est-à-dire indéfiniment sur un direct qui s'arrête. Le test l'a montré avant
  l'antenne.

### La désignation — la seule écriture du chantier

`!montre <nom>` fait monter une carte du classeur sur le calque. C'est la seule
commande qui écrive, et elle a attendu longtemps parce qu'écrire demandait soit
d'ouvrir une table aux écritures anonymes, soit la clé de service. **La clé de
service est écartée par doctrine** — elle contournerait la portée choisie dans
l'écran de partage, ce qui est l'unique erreur qui rendrait ce bot dangereux.
Restait à borner l'écriture anonyme assez pour qu'elle soit sans conséquence.

**Ce qu'un inconnu peut faire au pire.** Il connaît l'adresse de partage — elle
est à l'antenne — et appelle `public_request_spotlight` directement, sans passer
par le chat ni par le débit du bot. Il peut alors faire monter, une fois toutes
les trente secondes, **une carte que le propriétaire possède déjà et donne déjà à
lire**. Rien d'autre : la fonction ne touche qu'une table qui n'existe que pour
ça, n'accepte aucun texte libre hors un pseudonyme borné à quarante caractères,
et la table ne grossit pas — une ligne par collection, écrasée.

Trois verrous, tous mécaniques : `collection_by_handle` refuse une collection non
publiée ; la case doit être **possédée**, sans quoi on ferait défiler les 165 000
impressions du catalogue ; et le délai de garde se lit dans la ligne précédente,
qui porte son heure — pas de table de compteurs.

**Trente secondes, et d'où vient ce nombre.** C'est le délai par recherche du bot
(`DEFAULT_QUERY_COOLDOWN_SECONDS`), choisi pour exactement cette raison : « éviter
de réécrire une réponse encore à l'écran ». La seule contrainte dure est qu'il
dépasse `overlayLinger`, la durée d'affichage du calque — douze secondes ; en
deçà, une demande remplacerait une carte que le demandeur précédent n'a pas fini
de voir.

**La lecture est l'autorité sur la portée, pas l'écriture.** `shared_sets`
s'applique dans `public_spotlight`, une seule fois. C'est ce qui fait qu'une
extension retirée du partage **après** la demande disparaît du calque : le
partage est révocable, y compris a posteriori. Un filtre posé côté écriture
passerait tous les autres contrôles et manquerait celui-là — c'est le sixième
contrôle de `app.measure.spotlight_rls`, et le seul qui ne se déduise d'aucune
lecture du code.

**Côté bot, la sécurité tient à l'ordre lecture → écriture.** `!montre` passe par
`binder_locate` — la même fonction que `!card`, `SECURITY INVOKER`, sous la clé
anonyme — et n'écrit que ce que celle-ci a bien voulu rendre. Un spectateur ne
peut donc désigner que ce qu'il pouvait déjà voir, **sans qu'une seule ligne de
Python ne le vérifie**. Un test l'exige : une carte absente ne doit produire
aucun appel d'écriture.

**Le scan prime sur la demande.** Une carte scannée est physiquement devant
l'objectif ; une désignation n'est qu'une curiosité. Mais une demande évincée
n'est **pas perdue** : elle n'est marquée vue qu'au moment de s'afficher, si bien
qu'elle remonte une fois le scan effacé. La laisser tomber ferait disparaître
sans trace la demande d'un spectateur, et il n'y a pas de file pour la rattraper.

**Un refus dit quoi faire, contrairement à un refus de débit.** « L'écran est
déjà pris — réessaie dans un instant » : la commande a été acceptée et la
recherche a eu lieu, se taire laisserait croire à une panne. Le silence reste la
règle quand c'est le débit qui refuse, avant tout travail.

### Le classeur qui s'ouvre — ce que voit le spectateur

Une désignation n'affiche pas une bannière : elle **ouvre un classeur**, le
feuillette jusqu'à la page de la carte, et la fait sortir de sa case
(`binder_reveal.dart`). Le classeur est la métaphore centrale du produit — une
bannière montre *une carte*, une page de classeur montre **où elle vit**. `!card`
répond déjà « page 3 case 4 » ; le calque le montre au lieu de l'écrire.

**Le défilé part de la page 1, et ce n'est pas un mensonge.** Quand on va
chercher une carte dans un classeur, on l'ouvre au début et on feuillette :
partir de la première page est le geste exact. Le numéro défile avec les pages et
s'arrête sur le bon, si bien que le feuilletage **dit** la distance parcourue au
lieu de seulement l'illustrer.

**Ce qui le rend bon marché** : les pages qui défilent sont **génériques**, et
montrent le **dos des cartes**. À vingt-quatre millisecondes la page personne ne
lit rien, et charger quarante-cinq vraies pages coûterait quarante-cinq appels
réseau pour du flou. Le dos est **dessiné**, non chargé : la face cachée d'une
carte Magic est une œuvre de l'éditeur, et le projet ne réhéberge rien (§IV.3).
Seule la page qui se pose est réelle — un unique appel à `public_binder_page`,
lancé à l'arrivée de la demande et non à chaque interrogation.

**C'est la page du classeur, et elle doit s'y ressembler.** Une première version
dessinait les neuf cases en aplats gris, au motif qu'à cette taille neuf
illustrations se disputeraient le regard. L'argument tombe devant l'écran de
collection, qui en affiche neuf depuis toujours et reste lisible : **c'est la
même page**, montrée ailleurs. Les cases portent donc les mêmes cartes, avec le
même vocabulaire — case pleine à l'illustration et son reflet de brillante, case
vide en **fantôme à un quart d'opacité** avec son numéro par-dessus, « un manque
qu'on montre, pas une carte ». Cela a demandé deux colonnes de plus à
`public_binder_page` : `art_crop_url` et `has_foil`.

**Les couleurs viennent du thème, pas du calque.** `Theme.of(context)` rend le
nuancier de l'application — sombre, doré. Recopier des valeurs hexadécimales
aurait fait diverger le calque de l'écran qu'il représente au premier changement
de thème ; c'est exactement ce qui lui donnait un air de panneau bleu-violet
étranger au produit. Et les illustrations passent par `CardImage`, **jamais** par
`Image.network` : c'est le point de passage unique où l'URL est composée, et le
contourner a déjà coûté 20 964 cartes Pokémon dont aucune ne s'affichait. Un test
vérifie que toute `Image` de la planche porte un `CardImageProvider`.

**La page de destination est dessous dès le premier tour.** Ne la peupler qu'à la
fin faisait apparaître ses neuf cartes d'un coup ; les feuilles qui passent la
découvrent par morceaux, comme un vrai feuilletage. Et **la case visée ne se vide
qu'au départ de la carte** — le trou doit apparaître avec le mouvement, sinon la
carte semble sortir d'une case déjà vide.

**Le tempo est borné par `overlayLinger`.** Douze secondes d'affichage : une
intro de plus de deux secondes et demie mangerait le temps qu'on a pour
*regarder* la carte. D'où 300 ms d'ouverture, un feuilletage plafonné à 1,2 s
quel que soit le nombre de pages, 250 ms pour que la case s'allume, 550 ms de
sortie — 2,3 s au pire, près de dix secondes de carte stable.

**La page et la case viennent de la base.** `public_spotlight` les calcule avec
l'arithmétique de `binder_locate`, copiée à l'identique. Les recalculer en Dart y
porterait l'ordre des numéros, le repli quand le numéro n'est pas un nombre et le
choix de l'impression représentative — un jumeau de plus sur exactement le genre
de règle qui dérive en silence, et **un calque qui ouvre la page 46 quand le
classeur en montre 45 n'affiche aucune erreur : il montre une page fausse**.
Vérifié sur 25 cartes de la collection réelle, pages 1 à 36 : zéro désaccord.

**Un scan garde la bannière, et c'est la fréquence qui le décide.** Pendant un
booster les cartes s'enchaînent toutes les dix secondes ; la même animation
quinze fois d'affilée épuiserait, et le calque ne se tairait jamais. Une
désignation est rare — trente secondes de délai de garde au minimum — et
délibérée : elle mérite le geste.

### Trois défauts que seule l'image rendue a montrés

Aucun test ne mesure « est-ce que ça a l'air d'un classeur ». Il a fallu rendre
la planche et la regarder.

- **Ça ne ressemblait pas à un classeur** — un panneau sombre avec une grille. Le
  dos, ses trois anneaux et une page d'une autre matière que la couverture
  suffisent à le faire lire.
- **Cases pleines et vides étaient indiscernables**, dessinées dans deux gris
  voisins. Sur la capture, une case possédée juste à côté de la carte demandée
  passait pour un trou — c'est-à-dire que les voisines ne servaient à rien.
- **Le halo remplissait la case au lieu de la creuser.** Une `BoxShadow` peint un
  rectangle plein *derrière* la boîte : sans couleur de fond explicite, le halo
  traversait le vide et l'on lisait « carte présente » là où l'on voulait montrer
  le trou qu'elle laisse.
- **Les feuilles qui tournent débordaient du classeur.** Passé le quart de tour,
  une page est de l'autre côté du dos ; sans rognage à la couverture elle
  flottait sur la vidéo. Elle s'efface désormais en franchissant le dos, ce qui
  est aussi plus juste que la traîner jusqu'au demi-tour.

Un quatrième, celui-là pris par un test : le repli de l'illustration affichait le
nom de la carte, que la légende porte déjà — **deux « Ka-Zar » à l'écran**. Il
affiche désormais le numéro de case.

**Pour regarder l'animation**, sans base ni compte :

```bash
cd app && flutter run -d chrome -t tool/apercu_montre.dart
```

L'aperçu importe `BinderReveal` **tel quel** — géométrie, tempo et couleurs sont
ceux du direct. Un aperçu qui recopierait le dessin ne mesurerait que lui-même,
faute déjà payée sur `probe_photo` et `recette.dart`. Il propose les trois
distances qui comptent — page 1 sans feuilletage, page 12 court, page 48 presque
au plafond (1 128 ms sur 1 200) — parce que c'est la seule façon de juger si le
plafond tombe au bon endroit. Le bandeau affiche les deux durées.

Le rendu **en conditions réelles** — la vraie collection, le vrai chat — demande
`flutter build web` puis un navigateur sur `?o=<adresse>`, la collection publiée
le temps de la capture. C'est ce chemin-là qui a montré les trois défauts
ci-dessus ; l'aperçu sert aux suivants.

### Ce qui a de la valeur pour un spectateur

La carte comble-t-elle une case vide, ou est-ce un doublon ? `copies_before` est
la somme des mouvements antérieurs sur la même impression — le journal la porte
déjà. C'est l'information que l'issue réclamait, et elle ne coûte rien.

L'attribution Scryfall est **sur le calque**, garde-fou §IV.2 : un overlay est vu
par plus d'inconnus qu'un écran « à propos ».

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
