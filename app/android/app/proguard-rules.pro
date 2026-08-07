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
