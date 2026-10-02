{{flutter_js}}
{{flutter_build_config}}

// Polices de secours (emoji, alphabets non latins) servies par DeckHand, et non
// par fonts.gstatic.com : tools/web/fallback_fonts.sh les copie dans
// fonts/fallback/ au build. Chemin absolu : la page d'un classeur a des routes profondes.
_flutter.loader.load({
  serviceWorkerSettings: {
    serviceWorkerVersion: {{flutter_service_worker_version}},
  },
  config: {
    fontFallbackBaseUrl: "/fonts/fallback/",
  },
});
