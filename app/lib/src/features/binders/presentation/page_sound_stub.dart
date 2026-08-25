/// Le silence : ce que le calque joue partout où il n'y a pas de navigateur.
///
/// Mobile, bureau, `flutter test` — le calque n'y tourne pas, et rien ne doit y
/// échouer pour autant. Voir `page_sound.dart` pour le pourquoi de l'import
/// conditionnel.
library;

import 'page_sound.dart';

PageSound createPageSound() => const _Silence();

class _Silence implements PageSound {
  const _Silence();

  @override
  void turn() {}

  @override
  void unlock() {}

  @override
  PageSoundStatus get status => PageSoundStatus.silencieux;

  @override
  void dispose() {}
}
