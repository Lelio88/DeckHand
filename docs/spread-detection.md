> **Chantier repris par une autre voie.** Tout ce qui suit concerne la
> segmentation d'image — découper la photo pour isoler chaque carte — qui a
> plafonné à 57 % de rappel. Cette approche est **abandonnée**, non parce
> qu'elle était mal menée, mais parce que la lecture de texte embarquée l'a
> rendue inutile : chaque carte porte son nom, et un nom retrouvé au catalogue
> *est* une carte détectée. La séparation devient un effet de bord de la lecture
> au lieu d'un problème à résoudre. Voir
> `app/lib/src/features/scan/domain/spread_names.dart`.
>
> La voie retenue est mesurée à son tour : **cinq cartes sur cinq, sans fausse**,
> sur un étalement photographié à main levée — contre 57 % de rappel au mieux
> par segmentation. Le réglage et sa limite structurelle sont documentés dans
> [`architecture.md`](./architecture.md), section « Étalement ».
>
> Le document reste ici parce que ses impasses valent pour toute tentative
> future de segmentation — si l'on y revient un jour, pour compter deux
> exemplaires identiques par exemple, ce que la lecture des noms ne sait pas
> faire.

# Détection multi-cartes — état de la recherche

Annexe de [`architecture.md`](./architecture.md). Consigne ce qui a été essayé
pour le **jalon 3** (étalement de plusieurs cartes sur une table), avec les
mesures obtenues. **Aucune approche n'est retenue en l'état.**

Ce document existe pour éviter de refaire ce chemin.

## Le problème

Trouver chaque carte dans une photo d'étalement, puis en extraire l'illustration.
Le reste de la chaîne — empreinte, recherche, confiance — est déjà validé et ne
change pas.

Contrainte structurante : l'algorithme doit être **réimplémenté en Dart**, comme
l'empreinte, puisque la reconnaissance s'exécute embarquée. Cela exclut OpenCV,
dont la richesse serait impossible à porter à la main.

## Protocole de mesure

Quatre photos d'étalement composées à partir de vraies cartes Scryfall, avec
vérité terrain connue : 30 cartes au total, disposées en grilles de 2×2 à 3×3,
sur fond de table texturé, légèrement tournées (±6°), avec ombres portées,
éclairage inégal et compression JPEG.

Une détection compte comme juste si son recouvrement (IoU) avec la carte réelle
dépasse 0,5.

## Résultats

| Approche | Rappel | Précision | IoU moyen |
|---|---|---|---|
| Densité de détail, seuil au 62ᵉ centile | 30 % | 100 % | 0,95 |
| Densité de détail, **seuil d'Otsu** | **57 %** | **100 %** | **0,95** |
| Densité de détail + fermeture (rayon 5) | 53 % | 100 % | 0,95 |
| Densité de détail + fermeture (rayon 12) | 10 % | 75 % | — |
| Soustraction du fond | 7 % | 100 % | 1,00 |

**La meilleure reste la densité de détail avec seuil d'Otsu : 57 % de rappel,
100 % de précision.**

## Ce que les mesures ont appris

**La précision n'est jamais le problème.** Toutes les approches atteignent ou
frôlent 100 %, avec un recouvrement de 0,95. Quand une carte est trouvée, elle
l'est très bien. Le sujet est entièrement le rappel.

**Les cartes ne sont pas manquées, elles sont pulvérisées.** L'analyse des rejets
est sans ambiguïté : 5739 composantes écartées comme trop petites, alors qu'une
vraie carte occupe 6 à 19 % de l'image. Une carte contient des zones lisses — le
ciel d'une illustration, les marges — qui coupent la région en fragments.

**Fermer les trous soude les cartes voisines.** La fermeture morphologique est la
réponse classique à la fragmentation. Ici elle dégrade tout : au rayon nécessaire
pour combler l'intérieur d'une carte, elle franchit aussi l'espace qui la sépare
de sa voisine, et l'étalement entier devient une seule composante. Le rappel
tombe à 10 %.

**Chercher le fond plutôt que les cartes ne suffit pas non plus.** Une table
réelle est texturée ; sa distance à la couleur médiane varie assez pour produire
des milliers de fragments à son tour.

## Pistes non explorées

- **OpenCV via liaison native** (`opencv_dart`) — détection de contours et
  approximation polygonale y sont matures. Coût : mobile uniquement, et abandon
  de la promesse d'un pipeline Dart pur.
- **Grille guidée** — l'application affiche des emplacements, l'utilisateur y
  pose ses cartes. Supprime la détection au prix d'une contrainte de geste.
- **Segmentation par projection** — exploiter le fait qu'un étalement est
  généralement ordonné en lignes et colonnes ; les profils de projection y font
  apparaître des creux réguliers. Fragile dès que la disposition est libre.
- **Détection de segments droits** (transformée de Hough simplifiée) puis
  recherche de quadrilatères. Plus proche du problème réel — une carte est un
  rectangle — mais nettement plus de code.

## Conséquence pour le produit

En l'état, 57 % de rappel signifie qu'il faudrait deux à trois photos pour
capturer un étalement complet. La précision parfaite rend malgré tout l'approche
utilisable : ce qui est détecté est juste, et l'utilisateur photographierait le
reste. C'est une expérience dégradée, pas une impasse.

Le jalon 2 — une carte à la fois — ne dépend en rien de ce travail et
fonctionne.

---

# Deuxième vague d'impasses : distinguer un nom d'une citation

L'approche par lecture de noms a remplacé le découpage d'image et fonctionne —
17 cartes sur 17 sur une photo à plat. Deux fausses cartes résistent pourtant, et
les pistes bon marché pour les écarter ont toutes été mesurées puis abandonnées.

**Le cas restant.** Le texte d'ambiance, en bas d'une carte, cite un personnage
qui porte souvent le nom d'une vraie carte : « —Ka-Zar of the Savage Land ». Le
tiret d'ouverture suffit dans la plupart des cas et coûte zéro (aucun des 63 220
noms n'en porte), mais **la reconnaissance manque parfois ce tiret** : sur quatre
lectures de Ka-Zar, trois le portaient et une non. Celle-là passe. S'y ajoute
« Sacrificz », mot de règles capitalisé en début de phrase, que rien ne signale.

## Les rangées — les faux positifs tombent dessus

*Hypothèse* : les cartes sont posées en rangées, les vrais noms sont donc alignés
en hauteur, tandis qu'une attribution siège au bas de sa carte.

*Mesuré* : les onze vrais noms forment bien quatre rangées nettes
(y ≈ 0,172 / 0,387 / 0,594 / 0,821, écarts de 0,19 entre rangées contre 0,02 à
l'intérieur). Mais **les quatre faux positifs tombent tous sur une rangée**, à
0,013 à 0,020 près.

*Pourquoi* : les cartes sont posées bord à bord. Le bas d'une carte de la rangée
N — donc son texte d'ambiance — se trouve à la même hauteur que le haut de la
carte de la rangée N+1, donc que son nom. Les deux populations se superposent par
construction, quelle que soit la finesse du regroupement.

## La taille du texte, deuxième tentative

Le filtre de taille avait déjà été abandonné pour trier les 141 lignes lues.
Question plus étroite ici : parmi les lignes qui ont **survécu à tous les filtres
et trouvé une carte**, la taille sépare-t-elle les vraies des fausses ? Le nom est
imprimé plus gros que le texte d'ambiance.

*Mesuré sur la photo à doublons* : vraies cartes 13 à 19 px, fausses 12 à 18 px.
**Les intervalles se chevauchent** — une attribution mesurait 18 px quand un vrai
nom en mesurait 13.

*Coût vérifié sur la photo à plat*, où aucune fausse n'apparaît : un seuil à
1,2 fois la médiane des lignes ferait perdre **15 cartes sur 17**. Toute valeur
plus haute les perd toutes.

## Ce qu'il resterait

Les deux faux positifs restants ont la même cause profonde : **on ne sait pas à
quelle carte appartient une ligne**. Un nom et une citation ne se distinguent
que par leur place *dans leur carte* — en haut, en bas —, information qu'aucune
mesure globale ne peut reconstituer.

C'est le chantier « détecter les bords d'une carte », dont la première vague
d'impasses est consignée plus haut. Il reste ouvert, et il résoudrait d'un coup
plusieurs limites : rattacher chaque ligne à sa carte, compter les cartes
physiquement présentes, et écarter les citations.

