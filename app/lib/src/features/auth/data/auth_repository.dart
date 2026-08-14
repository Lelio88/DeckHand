/// Authentification, adossée à Supabase Auth.
///
/// Les collections étant protégées par RLS, aucune carte ne peut être enregistrée
/// sans utilisateur connecté. La recherche, elle, reste ouverte : le catalogue est
/// public.
///
/// La confirmation par e-mail est désactivée côté projet — l'inscription ouvre
/// donc immédiatement une session. C'est un choix assumé pour un usage privé
/// entre proches ; il serait à revoir si l'application devenait ouverte à tous.
///
/// **Ce choix rend la réinitialisation indispensable plutôt que confortable.**
/// Une adresse non vérifiée peut être mal saisie, et un mot de passe qu'on tape
/// une seule fois à l'aveugle aussi. Sans route de retour, une frappe de travers
/// à l'inscription rend le compte irrécupérable — avec la collection dedans, qui
/// est ce que ce produit demande des heures à constituer.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class AuthRepository {
  const AuthRepository(this._client);

  final GoTrueClient _client;

  Session? get currentSession => _client.currentSession;

  /// Émet à chaque connexion, déconnexion ou rafraîchissement de jeton.
  Stream<AuthState> get changes => _client.onAuthStateChange;

  Future<void> signIn({required String email, required String password}) {
    return _client.signInWithPassword(email: email, password: password);
  }

  Future<void> signUp({required String email, required String password}) {
    return _client.signUp(email: email, password: password);
  }

  Future<void> signOut() => _client.signOut();

  /// Envoie le lien de réinitialisation à [email].
  ///
  /// Supabase répond de la même façon que l'adresse ait un compte ou non : rien
  /// à faire ici pour éviter d'en faire un test d'existence de compte, mais
  /// l'écran doit tenir le même silence.
  Future<void> sendPasswordReset(String email) {
    return _client.resetPasswordForEmail(email, redirectTo: passwordResetLink);
  }

  /// Remplace le mot de passe de la session courante.
  ///
  /// Vaut pour une session ordinaire comme pour la session temporaire ouverte
  /// par un lien de réinitialisation : c'est la même autorisation.
  Future<void> updatePassword(String password) {
    return _client.updateUser(UserAttributes(password: password));
  }
}

/// Adresse que suit le lien de réinitialisation reçu par courriel.
///
/// **Un schéma propre à l'application plutôt qu'une adresse web.** Le lien doit
/// rouvrir DeckHand pour que `supabase_flutter` échange son code et ouvre la
/// session temporaire ; une adresse `https://` mènerait au navigateur, où la
/// version hébergée ne sait rien faire d'un compte (`DECKHAND_PUBLIC_ONLY`).
///
/// Deux endroits doivent la connaître, faute de quoi le lien ne mène nulle part
/// sans que rien ne le signale : l'`AndroidManifest` doit déclarer le schéma
/// `deckhand`, et la console Supabase doit l'autoriser dans
/// *Authentication → URL Configuration → Redirect URLs*.
const String passwordResetLink = 'deckhand://reset-password';

/// Vrai quand un lien de réinitialisation vient de rouvrir l'application.
///
/// **Ce drapeau existe parce qu'une session de récupération est une session
/// valide.** Rien ne la distingue d'une connexion ordinaire, sinon l'événement
/// qui l'a créée : sans le retenir, l'application ouvrirait l'écran d'accueil et
/// l'utilisateur n'aurait jamais l'occasion de choisir son nouveau mot de passe.
///
/// **L'abonnement doit précéder l'événement.** Le flux d'authentification ne
/// rejoue pas ce qui est passé : un `passwordRecovery` émis avant que ce
/// notifieur n'existe est perdu, et le lien de réinitialisation ouvrirait
/// simplement l'accueil. C'est pourquoi l'aiguillage de `main.dart` l'observe
/// dès son premier build, avant même de regarder la session — et non au moment
/// où il en aurait besoin.
class PasswordRecovery extends Notifier<bool> {
  @override
  bool build() {
    final subscription = ref.watch(authRepositoryProvider).changes.listen((
      state,
    ) {
      if (state.event == AuthChangeEvent.passwordRecovery) this.state = true;
    });
    ref.onDispose(subscription.cancel);
    return false;
  }

  /// Referme le mode : le mot de passe est remplacé, la session redevient
  /// ordinaire. Sans cet appel, l'écran resterait affiché indéfiniment.
  void clear() => state = false;
}

final passwordRecoveryProvider = NotifierProvider<PasswordRecovery, bool>(
  PasswordRecovery.new,
);

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => AuthRepository(Supabase.instance.client.auth),
);

/// Session courante, réévaluée à chaque changement d'état d'authentification.
///
/// La valeur initiale vient de `currentSession` et non du flux : au démarrage,
/// Supabase restaure une session persistée de façon synchrone, et attendre le
/// premier événement ferait clignoter l'écran de connexion.
final sessionProvider = StreamProvider<Session?>((ref) async* {
  final repository = ref.watch(authRepositoryProvider);
  yield repository.currentSession;
  yield* repository.changes.map((state) => state.session);
});
