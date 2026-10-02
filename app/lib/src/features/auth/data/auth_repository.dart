/// Authentification, adossée à Supabase Auth — par e-mail et mot de passe, ou
/// par un compte Google.
///
/// Les collections étant protégées par RLS, aucune carte ne peut être enregistrée
/// sans utilisateur connecté. La recherche, elle, reste ouverte : le catalogue est
/// public.
///
/// **L'adresse est confirmée par courriel avant la première connexion.** Le
/// lien reçu rouvre l'application (`deckhand://login-callback`), qui échange
/// son code et ouvre la session. C'est ce qui permet de ne jamais dire qu'une
/// adresse est déjà inscrite (voir [blindSignUp]), et ce qui ferme la trappe
/// d'une adresse mal tapée à l'inscription : un compte ne naît plus sur une
/// adresse que personne ne lit.
///
/// **La réinitialisation reste indispensable plutôt que confortable.** Un mot de
/// passe tapé à l'aveugle peut être faux ; sans route de retour, le compte serait
/// perdu — avec la collection dedans, qui est ce que ce produit demande des
/// heures à constituer.
///
/// **Google** : le sélecteur natif rend un jeton d'identité, échangé contre une
/// session (`signInWithIdToken`). Un compte dont l'adresse est déjà inscrite par
/// e-mail est **retrouvé** — Supabase lie les identités d'une même adresse
/// vérifiée — et un compte connecté peut lier Google lui-même depuis l'écran
/// Compte (`linkIdentityWithIdToken`, liaison manuelle activée côté projet).
library;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/google_link.dart';
import 'google_id_token_source.dart';

class AuthRepository {
  AuthRepository(this._supabase, {this._google});

  final SupabaseClient _supabase;
  final GoogleIdTokenSource? _google;

  GoTrueClient get _client => _supabase.auth;

  Session? get currentSession => _client.currentSession;

  /// Émet à chaque connexion, déconnexion, rafraîchissement de jeton ou
  /// changement du compte (identité liée ou déliée).
  Stream<AuthState> get changes => _client.onAuthStateChange;

  /// L'adresse du compte connecté, pour que l'écran Compte dise qui l'on est.
  String? get email => _client.currentUser?.email;

  Future<void> signIn({required String email, required String password}) {
    return _client.signInWithPassword(email: email, password: password);
  }

  /// Inscrit [email] ; rend vrai quand le compte attend la confirmation de son
  /// adresse — ce qui, vu d'ici, est toujours le cas d'une adresse déjà prise.
  Future<bool> signUp({required String email, required String password}) {
    return blindSignUp(
      () => _client.signUp(
        email: email,
        password: password,
        // Le lien du courriel de confirmation mène ici : le schéma rouvre
        // l'application, qui échange le code et ouvre la session. L'adresse
        // doit figurer dans les retours autorisés du projet Supabase.
        emailRedirectTo: loginCallbackLink,
      ),
    );
  }

  Future<void> signOut() async {
    // Google d'abord : la personne suivante sur ce téléphone doit retrouver le
    // sélecteur, et non être reconnectée à ce compte sans l'avoir choisi.
    await _google?.forget();
    await _client.signOut();
  }

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

  /// Supprime le compte et tout ce qui s'y rattache, définitivement.
  ///
  /// `delete_my_account` efface l'utilisateur de la session — l'identifiant
  /// vient du jeton, jamais d'un paramètre — et la base emporte le reste en
  /// cascade : collection, classeurs, journal, préférences, partage, clé du
  /// calque. L'accès de DeckHand au compte Google est ensuite retiré.
  Future<void> deleteAccount() async {
    await _supabase.rpc<void>('delete_my_account');
    await _google?.forget(revoke: true);
    try {
      await _client.signOut();
    } on AuthException {
      // Le compte n'existe plus : le serveur peut refuser de fermer une session
      // qu'il ne connaît plus. La session locale, elle, est déjà effacée.
    }
  }

  /// Vrai quand « Continuer avec Google » peut s'afficher sur cet appareil.
  bool get supportsGoogle => _google?.isAvailable ?? false;

  /// Connecte avec un compte Google ; rend faux si l'utilisateur a refermé le
  /// sélecteur. Un compte Google sans compte DeckHand en crée un.
  Future<bool> signInWithGoogle() async {
    final idToken = await _pickGoogleAccount();
    if (idToken == null) return false;
    await _client.signInWithIdToken(
      provider: OAuthProvider.google,
      idToken: idToken,
    );
    return true;
  }

  /// Le compte Google lié au compte connecté, ou `null` — lu dans la session,
  /// sans réseau.
  GoogleLink? get linkedGoogle => googleLinkOf(_client.currentUser);

  /// Lie un compte Google au compte connecté et laisse [linkedGoogle] à jour ;
  /// rend faux si l'utilisateur a refermé le sélecteur. Un compte Google déjà
  /// lié à ce compte n'est pas une erreur ; lié à un autre, si.
  Future<bool> linkGoogle() async {
    final idToken = await _pickGoogleAccount();
    if (idToken == null) return false;
    await linkThenRefresh(
      link: () => _client.linkIdentityWithIdToken(
        provider: OAuthProvider.google,
        idToken: idToken,
      ),
      refresh: _client.refreshSession,
    );
    return true;
  }

  /// Délie le compte Google, s'il n'est pas le seul moyen de connexion.
  Future<void> unlinkGoogle() async {
    final identities = await _client.getUserIdentities();
    final google = identities.where((i) => i.provider == 'google').firstOrNull;
    if (google == null) return;
    if (identities.length < 2) {
      // Supabase le refuse aussi ; échouer ici épargne un aller-retour.
      throw const AuthException(
        'Google is the only identity',
        code: 'single_identity_not_deletable',
      );
    }
    await _client.unlinkIdentity(google);
    // `unlinkIdentity` laisse l'utilisateur en cache tel quel : rafraîchir
    // pour que [linkedGoogle] lise les identités nouvelles.
    await _client.refreshSession();
    await _google?.forget();
  }

  Future<String?> _pickGoogleAccount() {
    final google = _google;
    if (google == null || !google.isAvailable) {
      throw const AuthException(
        'Google sign-in is not available here',
        code: 'google_sign_in_failed',
      );
    }
    return google.pickAccount();
  }
}

/// Le compte Google lié à [user], ou `null` — lu dans les identités que
/// Supabase rend avec la session.
@visibleForTesting
GoogleLink? googleLinkOf(User? user) {
  final identities = user?.identities ?? const <UserIdentity>[];
  final google = identities.where((i) => i.provider == 'google').firstOrNull;
  if (google == null) return null;
  return GoogleLink(
    email: google.identityData?['email'] as String?,
    canUnlink: identities.length > 1,
  );
}

/// Lie une identité, puis rafraîchit la session pour qu'elle y figure.
///
/// **GoTrue répond à une liaison avec l'utilisateur chargé avant elle** :
/// l'identité est insérée en base sans être ajoutée à l'utilisateur renvoyé,
/// et c'est lui que le client enregistre. Sans le rafraîchissement, qui
/// recharge l'utilisateur depuis la base, [googleLinkOf] ne voit toujours pas
/// Google et l'écran Compte propose de le lier encore.
///
/// Une identité **déjà liée à ce compte** (`identity_already_exists` avec
/// « Identity is already linked », et non « … to another user ») veut dire
/// qu'une session périmée la cachait : rien à lier, le rafraîchissement la
/// révèle. Tout autre échec remonte, sans rafraîchissement.
@visibleForTesting
Future<void> linkThenRefresh({
  required Future<void> Function() link,
  required Future<void> Function() refresh,
}) async {
  try {
    await link();
  } on AuthException catch (e) {
    if (!isAlreadyLinkedToCaller(e)) rethrow;
  }
  await refresh();
}

/// Vrai quand GoTrue refuse une liaison parce que l'identité est **déjà à
/// l'appelant**. Le même code sert pour une identité liée à un autre compte :
/// seul le texte (« … to another user ») les sépare.
bool isAlreadyLinkedToCaller(AuthException e) =>
    e.code == 'identity_already_exists' &&
    !e.message.toLowerCase().contains('another user');

/// Joue une inscription et répond si elle attend le courriel de confirmation,
/// **sans jamais révéler que l'adresse était déjà inscrite** (guide de
/// conformité, C2 — sinon le formulaire dit à qui veut quelles adresses ont un
/// compte).
///
/// Confirmation active, Supabase répond à un doublon confirmé par un
/// utilisateur factice (sans identité, sans session) et n'envoie rien ; un
/// doublon jamais confirmé reçoit de nouveau son courriel. Les deux se lisent
/// ici comme un compte neuf : pas de session, donc « Vérifiez vos e-mails ».
/// Cet écran renvoie aussi le titulaire vers la connexion et « Mot de passe
/// oublié », pour que personne ne reste bloqué. Un serveur qui annoncerait le
/// doublon (`user_already_exists`, seulement quand la confirmation est coupée)
/// reçoit la même réponse. **Ne jamais réintroduire un contrôle
/// `identities.isEmpty`** qui ferait du doublon une erreur.
@visibleForTesting
Future<bool> blindSignUp(Future<AuthResponse> Function() signUp) async {
  try {
    return (await signUp()).session == null;
  } on AuthException catch (e) {
    if (e.code == 'user_already_exists') return true;
    rethrow;
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
/// `deckhand`, et le projet Supabase doit l'autoriser dans ses adresses de
/// retour (`api/push_auth_config.py`).
const String passwordResetLink = 'deckhand://reset-password';

/// Adresse que suit le lien de confirmation d'une inscription. Mêmes
/// exigences que [passwordResetLink].
const String loginCallbackLink = 'deckhand://login-callback';

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
  (ref) => AuthRepository(
    Supabase.instance.client,
    google: NativeGoogleIdTokenSource(serverClientId: kGoogleWebClientId),
  ),
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
