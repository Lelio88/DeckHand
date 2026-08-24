import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Clé de signature de publication, **hors du dépôt**.
//
// `android/key.properties` pointe vers un keystore rangé dans
// `../.deckhand-secrets/` et porte ses mots de passe : ni l'un ni l'autre ne
// doit être versionné, le dépôt étant public (garde-fou §IV.7).
//
// Le fichier est **facultatif** : sans lui, la version release reste signée avec
// la clé de débogage pour que `flutter run --release` fonctionne sur le poste.
// C'est un piège connu — un AAB ainsi signé est refusé par Play, et le refus
// arrive après l'envoi — d'où l'avertissement bien visible plus bas.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKey = keystorePropertiesFile.exists()
if (hasReleaseKey) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "app.deckhand"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "app.deckhand"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // La clé de publication quand elle est là, celle de débogage sinon —
            // et dans ce cas on le dit, parce qu'un AAB signé en débogage est
            // accepté par Gradle et refusé par Play, bien plus tard.
            signingConfig = if (hasReleaseKey) {
                signingConfigs.getByName("release")
            } else {
                logger.warn(
                    "ATTENTION : android/key.properties absent — la version " +
                        "release est signée avec la clé de DÉBOGAGE. Play " +
                        "refusera cet AAB. Voir docs/publication-play.md.",
                )
                signingConfigs.getByName("debug")
            }
            // Nécessaire depuis l'ajout de la lecture de texte : voir le fichier
            // pour la raison — R8 bute sur des alphabets que nous n'embarquons pas.
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
        debug {
            // **Le build de mesure cohabite avec celui de Play.** Les deux sont
            // signés différemment, et Android refuse d'en installer un par-dessus
            // l'autre (INSTALL_FAILED_UPDATE_INCOMPATIBLE). Sans ce suffixe, faire
            // tourner un banc sur l'appareil exigeait de désinstaller
            // l'application réelle du propriétaire — puis de la réinstaller depuis
            // Play. Le suffixe ne touche que le type `debug` : l'AAB publié garde
            // `app.deckhand`.
            //
            // Conséquence à connaître : le build de debug lit son propre dossier
            // externe, `/sdcard/Android/data/app.deckhand.debug/files/`. C'est là
            // qu'un banc doit pousser ses photos.
            applicationIdSuffix = ".debug"
        }
    }
}

flutter {
    source = "../.."
}
