/// De quoi diagnostiquer une passe de scan, sans câble ni logcat (#8).
///
/// **Pourquoi à l'écran et pas seulement au journal.** Le journal de mesure
/// passe par `adb logcat`, donc par le débogage sans fil, qui retombe
/// régulièrement sur ce poste. Une passe de terrain qu'on ne peut pas relire
/// est une passe perdue : ce compteur vit donc dans l'application, lisible sur
/// place, et le journal reste pour qui veut le détail image par image.
///
/// **Ce qu'il sert à trancher.** « La carte n'est pas reconnue » recouvre trois
/// pannes qui ne se corrigent pas au même endroit :
///
/// | Ce que le compteur montre | Ce que ça veut dire | Le geste |
/// |---|---|---|
/// | beaucoup de `notFound` | la détection de bords ne trouve pas la carte | recadrer, changer l'éclairage ou le fond |
/// | beaucoup de `silent` | la carte est vue, son illustration ne ressemble à rien de l'index | vérifier le jeu saisi, ou le gabarit |
/// | beaucoup de `unsure` | deux cartes de l'index se ressemblent trop | c'est la marge de confiance qui protège, et elle fait son travail |
///
/// Sans cette ventilation, les trois se lisent « ça ne marche pas », et on
/// cherche au mauvais endroit.
library;

import 'live_scanner.dart';

/// Compte ce que le flux a produit depuis le début d'une passe.
class ScanTally {
  final Map<FrameOutcome, int> _counts = {
    for (final o in FrameOutcome.values) o: 0,
  };

  int _frames = 0;
  int _detections = 0;
  int _accepted = 0;

  /// Le meilleur candidat refusé le plus **proche** rencontré.
  ///
  /// C'est la valeur qui dit si une reconnaissance manquée est passée à un
  /// cheveu ou à un kilomètre — et donc s'il faut retoucher le cadrage ou
  /// chercher ailleurs.
  int? closestRejected;

  /// Images observées depuis le début de la passe.
  int get frames => _frames;

  /// Images sur lesquelles la détection de bords a tourné. Rapporté au total,
  /// c'est ce qui dit si le suivi du quadrilatère sert à quelque chose.
  int get detections => _detections;

  /// Cartes retenues, donc entrées au panier.
  int get accepted => _accepted;

  int count(FrameOutcome outcome) => _counts[outcome] ?? 0;

  /// Part des images où une carte était dans le champ.
  double get locatedShare =>
      _frames == 0 ? 0 : 1 - count(FrameOutcome.notFound) / _frames;

  void record(LiveObservation seen) {
    _frames++;
    if (seen.detected) _detections++;
    if (seen.accepted != null) _accepted++;
    _counts[seen.outcome] = count(seen.outcome) + 1;

    // On ne retient la distance que d'un candidat **refusé** : celle d'une
    // reconnaissance réussie n'apprend rien sur ce qui échoue.
    final distance = seen.distance;
    if (distance != null && seen.outcome != FrameOutcome.confident) {
      final best = closestRejected;
      if (best == null || distance < best) closestRejected = distance;
    }
  }

  void reset() {
    for (final o in FrameOutcome.values) {
      _counts[o] = 0;
    }
    _frames = 0;
    _detections = 0;
    _accepted = 0;
    closestRejected = null;
  }

  /// Une ligne lisible d'un coup d'oeil, pour l'écran comme pour le journal.
  String describe() {
    if (_frames == 0) return 'aucune image analysée';
    String pct(int n) => '${(100 * n / _frames).round()} %';
    return
        '$_frames images · '
        'sans carte ${pct(count(FrameOutcome.notFound))} · '
        'muet ${pct(count(FrameOutcome.silent))} · '
        'hésitant ${pct(count(FrameOutcome.unsure))} · '
        'reconnu ${pct(count(FrameOutcome.confident))} · '
        'détections ${pct(_detections)}'
        '${closestRejected == null ? '' : ' · refus le plus proche $closestRejected bits'}';
  }
}
