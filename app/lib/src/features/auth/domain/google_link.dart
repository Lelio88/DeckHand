/// Le compte Google lié au compte DeckHand, tel que la session le décrit.
library;

class GoogleLink {
  const GoogleLink({required this.email, required this.canUnlink});

  /// L'adresse du compte Google, quand Google l'a transmise.
  final String? email;

  /// Faux quand Google est le **seul** moyen de connexion : le délier rendrait
  /// le compte inaccessible, et Supabase le refuse de toute façon.
  final bool canUnlink;
}
