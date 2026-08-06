/// Authentification, adossée à Supabase Auth.
///
/// Les collections étant protégées par RLS, aucune carte ne peut être enregistrée
/// sans utilisateur connecté. La recherche, elle, reste ouverte : le catalogue est
/// public.
///
/// La confirmation par e-mail est désactivée côté projet — l'inscription ouvre
/// donc immédiatement une session. C'est un choix assumé pour un usage privé
/// entre proches ; il serait à revoir si l'application devenait ouverte à tous.
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
}

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
