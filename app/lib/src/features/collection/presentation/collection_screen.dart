/// Vue de la collection : ce que vous possédez, rangé comme dans un classeur.
///
/// **Il n'y a plus qu'une vue, et c'est le classeur.** La liste triable a existé
/// et a été retirée : chacun de ses services a trouvé un équivalent qui ne
/// dénature pas le rangement.
///
/// | Ce que la liste faisait | Ce qui le fait désormais |
/// |---|---|
/// | Trier par valeur, par nom | Les régimes de lecture du classeur |
/// | Filtrer sur la finition | Le filtre du classeur, trous conservés |
/// | Atteindre les cartes sans édition | La pile « à trier » |
/// | Chercher une carte par son nom | La recherche de l'étagère, qui donne la page |
/// | Ajouter, retirer, corriger l'édition | Les actions d'une case |
///
/// Ce qu'on y gagne est ce qu'aucune liste ne montrait : **les cases vides**.
/// Une liste dit ce qu'on possède ; un classeur dit ce qui manque.
///
/// Le poids de la collection — son nombre de cartes et sa valeur — est annoncé
/// par la barre du haut, qui le tient d'un appel distinct portant sur la
/// collection entière : aucun filtre de classeur ne le fait donc varier.
library;

import 'package:flutter/material.dart';

import '../../binders/presentation/binder_view.dart';

class CollectionScreen extends StatelessWidget {
  const CollectionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // **L'onglet n'attend plus le résumé pour montrer l'étagère.** Il le
    // demandait d'abord, et n'ouvrait le classeur qu'ensuite : deux allers-
    // retours en file là où deux suffisaient côte à côte, et le second ne
    // partait qu'une fois le premier revenu. Mesuré sous le rôle réel,
    // `my_collection_summary` puis `my_binder_shelf` coûtaient 0,82 s + 0,34 s
    // en série ; lancés ensemble, l'attente est celle du plus lent.
    //
    // **Ce qu'on perd en chemin, l'étagère le disait déjà mieux.** Le résumé ne
    // servait ici qu'à décider « collection vide », pour afficher un message
    // sans issue. `_Shelf` répond à la même question en offrant la pile « à
    // trier » et en distinguant les deux vides — des cartes qui attendent leur
    // édition, ou pas de cartes du tout. De même pour la panne : « Étagère
    // illisible » porte son bouton « Réessayer » et vise ce qui a réellement
    // échoué, là où « Collection illisible » rejouait le résumé.
    //
    // Le poids de la collection reste annoncé par la barre du haut, qui lit le
    // résumé de son côté et s'efface tant qu'il n'est pas là.
    return const BinderView();
  }
}
