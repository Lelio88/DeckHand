/// La session Supabase rangée dans le coffre chiffré du téléphone, et non en
/// clair dans les préférences.
///
/// **Pourquoi.** `supabase_flutter` garde par défaut la session — dont le jeton
/// de rafraîchissement, qui vaut un mot de passe tant qu'il n'est pas révoqué —
/// dans `SharedPreferences`, un fichier en clair. Le guide de conformité (C5)
/// demande le stockage sécurisé de la plateforme quand l'outil le permet :
/// `flutter_secure_storage` chiffre avec une clé du Keystore Android, qui ne
/// quitte pas l'appareil.
///
/// **Personne n'est déconnecté par la mise à jour.** Au premier lancement, la
/// session rangée à l'ancienne place est recopiée dans le coffre, **puis**
/// effacée : dans cet ordre, une coupure entre les deux laisse deux copies,
/// jamais aucune. Les lancements suivants n'y touchent plus.
///
/// **Un coffre illisible vaut une déconnexion, pas un plantage.** Une clé du
/// Keystore peut disparaître (restauration d'une sauvegarde sur un autre
/// téléphone, réinitialisation du verrouillage) : le contenu chiffré devient
/// indéchiffrable. La lecture rend alors « aucune session » et l'écran de
/// connexion s'affiche — ce qu'il faut faire de toute façon.
///
/// Sur le web, `main.dart` garde le stockage par défaut : la version publiée
/// ne connecte personne.
///
/// ```dart
/// FlutterAuthClientOptions(localStorage: SessionVault.forDevice(url))
/// ```
library;

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show LocalStorage;

/// Un magasin clé → texte, le coffre ou les préférences — un faux en test.
abstract interface class KeyValueVault {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SessionVault extends LocalStorage {
  SessionVault({
    required this.key,
    required this._vault,
    required this._legacy,
  });

  /// Le coffre du téléphone, sous la clé que `supabase_flutter` utilisait pour
  /// les préférences — c'est elle qui permet de retrouver l'ancienne session.
  factory SessionVault.forDevice(String supabaseUrl) => SessionVault(
    key: 'sb-${Uri.parse(supabaseUrl).host.split('.').first}-auth-token',
    vault: const _SecureVault(FlutterSecureStorage()),
    legacy: const _PreferencesVault(),
  );

  final String key;
  final KeyValueVault _vault;
  final KeyValueVault _legacy;

  @override
  Future<void> initialize() async {
    if (await _lire() != null) return;
    final ancienne = await _legacy.read(key);
    if (ancienne == null) return;
    await _vault.write(key, ancienne);
    await _legacy.delete(key);
  }

  @override
  Future<bool> hasAccessToken() async => await _lire() != null;

  @override
  Future<String?> accessToken() => _lire();

  @override
  Future<void> persistSession(String persistSessionString) async {
    try {
      await _vault.write(key, persistSessionString);
    } on PlatformException {
      // Coffre inutilisable : la session vaut pour ce lancement, et le suivant
      // redemandera une connexion. Faire échouer la connexion elle-même ne
      // rendrait service à personne.
    }
  }

  @override
  Future<void> removePersistedSession() async {
    await _vault.delete(key);
    // Une ancienne copie restée en clair ne doit pas survivre à une
    // déconnexion.
    await _legacy.delete(key);
  }

  Future<String?> _lire() async {
    try {
      return await _vault.read(key);
    } on PlatformException {
      // Coffre indéchiffrable : on l'efface pour repartir d'une connexion.
      try {
        await _vault.delete(key);
      } on PlatformException {
        // Rien de plus à tenter : la lecture rendra de nouveau `null`.
      }
      return null;
    }
  }
}

class _SecureVault implements KeyValueVault {
  const _SecureVault(this._storage);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class _PreferencesVault implements KeyValueVault {
  const _PreferencesVault();

  @override
  Future<String?> read(String key) async =>
      (await SharedPreferences.getInstance()).getString(key);

  @override
  Future<void> write(String key, String value) async =>
      (await SharedPreferences.getInstance()).setString(key, value);

  @override
  Future<void> delete(String key) async =>
      (await SharedPreferences.getInstance()).remove(key);
}
