# Reconnaissance de texte ML Kit — alphabets non embarqués.
#
# Le plugin `google_mlkit_text_recognition` référence les modules chinois,
# japonais, coréen et devanagari, que nous n'incluons pas : DeckHand ne lit que
# l'alphabet latin, et chaque modèle supplémentaire alourdit l'APK de plusieurs
# mégaoctets pour des cartes qui n'existent pas en français ni en anglais.
#
# R8 refuse de compiler tant que ces classes absentes ne sont pas explicitement
# tolérées. Les ignorer est sans risque : le code qui les instancie n'est jamais
# atteint, `TextRecognitionScript.latin` étant seul utilisé.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**

# Les registrars de ML Kit, que R8 ne voit appelés nulle part.
#
# **Panne constatée sur l'appareil, et silencieuse par construction.** En
# 1.8.1+15, `adb logcat` rendait au démarrage :
#
#     Could not instantiate com.google.mlkit.common.internal.CommonComponentRegistrar
#     Could not instantiate com.google.mlkit.vision.text.internal.TextRegistrar
#     Could not instantiate com.google.mlkit.vision.common.internal.VisionCommonRegistrar
#     Caused by: java.lang.NoSuchMethodException: ...<init> []
#
# puis, à la première photo :
#
#     E/MethodChannel#google_mlkit_text_recognizer: Failed to handle method call
#     java.lang.NullPointerException: ... on a null object reference
#
# Ces classes ne sont instanciées que par réflexion, au démarrage, par
# `MlKitInitProvider`. Rien ne les référence statiquement : R8 supprime donc
# leur constructeur sans rien signaler. ML Kit ne peut plus fabriquer le
# lecteur, l'appel lève, et `recognisePhoto` retombe sur l'illustration — le
# pipeline étant écrit pour ne jamais échouer bruyamment. Résultat : plus aucun
# nom lu, aucun message, et rien qu'un test sur machine puisse voir, ML Kit
# n'existant que sur l'appareil.
#
# **Ces règles manquaient déjà avant la panne.** Elle s'est déclarée en montant
# le greffon, mais la version qui marche ne marche que parce que les artefacts
# natifs qu'elle tire protègent encore ces classes d'eux-mêmes. C'est de la
# chance, pas une garantie : sans ces `-keep`, un prochain R8 ou un prochain
# jeu de dépendances ramène la même panne muette.
#
# Deux règles plutôt qu'une : la première nomme la forme observée, la seconde
# attrape tout registrar présent ou à venir, où qu'il vive.
-keep class com.google.mlkit.**.internal.*Registrar { <init>(); }
-keep class * implements com.google.firebase.components.ComponentRegistrar { <init>(); }
