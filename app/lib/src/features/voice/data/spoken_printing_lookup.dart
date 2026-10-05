/// Cherche au catalogue l'édition dite d'une carte dictée.
///
/// La moitié réseau de `domain/spoken_printing.dart` : le serveur ramène les
/// éditions de la carte qui contiennent un terme de la demande, le domaine les
/// trie. **Deux allers-retours au plus**, et seulement quand le premier terme
/// ne mène à rien : « mh 2 » se cherche d'abord comme le code MH2, puis comme
/// le mot « mh ».
///
/// **Le nombre d'éditions rapatriées est le plafond du serveur**, non la page
/// du sélecteur : un terme comme « commander » ramène des dizaines d'éditions
/// d'un terrain de base, et celle qu'on tient ne doit pas tomber hors de la
/// page.
///
/// Usage canonique :
///
/// ```dart
/// final found = await lookUpSpokenPrinting(
///   ref.read(printingRepositoryProvider),
///   oracleId: hit.oracleId,
///   lang: hit.matchedLang,
///   asked: const SpokenPrinting(set: 'm21', foil: true),
/// );
/// switch (found.resolution) { … }
/// ```
library;

import '../../printings/data/printing_repository.dart';
import '../domain/spoken_printing.dart';

/// Ce que la recherche a établi, et la recherche à rouvrir dans le sélecteur
/// quand il reste à choisir.
typedef SpokenPrintingLookup = ({
  PrintingResolution resolution,
  String? pickerQuery,
});

/// Plafond de `card_printings` : au-delà, le serveur coupe de toute façon.
const _lookupLimit = 200;

/// Confronte [asked] aux éditions de la carte [oracleId].
///
/// Une extension non dite n'appelle pas le serveur : c'est le remplissage des
/// éditions uniques qui s'en charge, en un seul aller-retour pour toute la
/// liste. Les erreurs du dépôt remontent telles quelles : à l'appelant de dire
/// que le catalogue est injoignable.
Future<SpokenPrintingLookup> lookUpSpokenPrinting(
  PrintingRepository repository, {
  required String oracleId,
  required String? lang,
  required SpokenPrinting asked,
}) async {
  for (final term in asked.searchTerms) {
    final candidates = await repository.forCard(
      oracleId,
      query: term,
      lang: lang,
      limit: _lookupLimit,
    );
    final resolution = resolveSpokenPrinting(asked, candidates);
    if (resolution is PrintingNotFound) continue;
    return (
      resolution: resolution,
      pickerQuery: _pickerQuery(resolution, term),
    );
  }
  return (resolution: const PrintingNotFound(), pickerQuery: null);
}

/// La recherche qui montrera, dans le sélecteur, les éditions entre lesquelles
/// choisir.
///
/// Une extension approchée, ou des variantes d'une même extension, se
/// montrent par son code, qui n'en ramène pas d'autre ; des extensions
/// différentes, par le terme qui les a trouvées.
String? _pickerQuery(PrintingResolution resolution, String term) {
  return switch (resolution) {
    PrintingApproximate(:final candidate) => candidate.setCode,
    PrintingAmbiguous(:final candidates)
        when candidates.map((p) => p.setCode).toSet().length == 1 =>
      candidates.first.setCode,
    PrintingAmbiguous() || PrintingNotInFoil() => term,
    PrintingRetained() || PrintingNotFound() => null,
  };
}
