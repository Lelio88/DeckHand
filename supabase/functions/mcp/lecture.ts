/**
 * lecture.ts — Les outils de lecture : chacun transmet une fonction SQL de
 * l'application, avec le jeton de l'utilisateur, et rend son résultat.
 *
 * Choix non évidents :
 * - **Aucun calcul ici.** Le moteur de suggestion, la valorisation et la
 *   recherche floue vivent en base ; un outil choisit seulement les colonnes
 *   utiles à un agent et pagine, pour ne pas noyer son contexte.
 * - **`cartes_jouables` filtre côté PostgREST** (identité de couleur, type,
 *   page) : une collection entière avec ses textes de règles dépasserait ce
 *   qu'un agent peut lire d'un coup.
 * - **L'attribution d'un deck voyage avec lui** (§IV.2) : `decks_suggeres`
 *   rend `source` et `attribution` sur chaque ligne, et les consignes du
 *   serveur demandent de les citer.
 */
import type { McpServer } from '@modelcontextprotocol/server'
import type { SupabaseClient } from '@supabase/supabase-js'
import { z } from 'zod'
import { JEUX } from './base.ts'
import { deciderNom } from './resolution.ts'
import { enJson, siErreur } from './reponse.ts'

const jeu = z.enum(JEUX).default('magic').describe('Jeu de cartes ; magic par défaut')
const couleur = z.enum(['W', 'U', 'B', 'R', 'G'])
const page = z.number().int().min(1).default(1).describe('Page, à partir de 1')
const LECTURE = { readOnlyHint: true, openWorldHint: false } as const

function tranche(numero: number, taille: number): { offset: number; fin: number } {
  const offset = (numero - 1) * taille
  return { offset, fin: offset + taille - 1 }
}

export function enregistrerLectures(server: McpServer, client: SupabaseClient): void {
  server.registerTool('resume_collection', {
    description: 'Chiffres de la collection : nombre de cartes, cartes distinctes, valeur totale en euros, ' +
      'carte la plus chère, extension la mieux remplie, cartes sans édition précisée.',
    inputSchema: z.object({ jeu }),
    annotations: LECTURE,
  }, async ({ jeu }) => {
    const { data, error } = await client.rpc('my_collection_summary', { p_game: jeu })
    siErreur('my_collection_summary', error)
    return enJson((data ?? [])[0] ?? null)
  })

  server.registerTool('ma_collection', {
    description: 'Les cartes possédées, une ligne par édition et finition, paginées. ' +
      'Une ligne sans extension est dans la pile à trier (édition non précisée).',
    inputSchema: z.object({
      jeu,
      recherche: z.string().max(200).optional().describe('Filtre sur le nom'),
      tri: z.enum(['name', 'price', 'quantity', 'recent', 'rarity', 'binder', 'number']).default('name'),
      decroissant: z.boolean().default(false),
      pile_seulement: z.boolean().default(false).describe('Seulement les cartes sans édition précisée'),
      page,
      par_page: z.number().int().min(1).max(100).default(50),
    }),
    annotations: LECTURE,
  }, async (a) => {
    const { offset } = tranche(a.page, a.par_page)
    const { data, error } = await client.rpc('my_collection', {
      p_query: a.recherche ?? null,
      p_sort: a.tri,
      p_descending: a.decroissant,
      p_unspecified_only: a.pile_seulement,
      p_limit: a.par_page,
      p_offset: offset,
      p_game: a.jeu,
    })
    siErreur('my_collection', error)
    return enJson({ page: a.page, cartes: data ?? [] })
  })

  server.registerTool('cartes_jouables', {
    description: 'Les cartes possédées légales dans un format, avec leur texte de règles, coût, type et ' +
      "identité de couleur : la matière pour construire un deck avec ce qu'on a. Magic seulement. " +
      "Filtrer par identité (couleurs d'un commandant) et par type pour réduire la liste.",
    inputSchema: z.object({
      format: z.enum(['commander', 'pauper', 'modern']),
      couleurs: z.array(couleur).max(5).optional()
        .describe("Identité de couleur contenue dans ces couleurs ; [] pour l'incolore seul"),
      type: z.string().max(60).optional().describe('Fragment de la ligne de type, ex. Creature, Instant'),
      page,
      par_page: z.number().int().min(1).max(200).default(100),
    }),
    annotations: LECTURE,
  }, async (a) => {
    const { offset, fin } = tranche(a.page, a.par_page)
    let requete = client.rpc('my_buildable_cards', { p_format: a.format, p_game: 'magic' }, { count: 'exact' })
    if (a.couleurs) requete = requete.containedBy('color_identity', a.couleurs)
    if (a.type) requete = requete.ilike('type_line', `%${a.type}%`)
    const { data, error, count } = await requete.order('name').range(offset, fin)
    siErreur('my_buildable_cards', error)
    return enJson({ total: count, page: a.page, cartes: data ?? [] })
  })

  server.registerTool('cartes_possedees', {
    description: "Pour une liste de noms (n'importe quelle langue), la carte reconnue, si le nom est exact, " +
      "combien en possède l'utilisateur, et son prix le plus bas. Utile pour confronter une liste de deck.",
    inputSchema: z.object({ jeu, noms: z.array(z.string().min(1).max(200)).min(1).max(200) }),
    annotations: LECTURE,
  }, async ({ jeu, noms }) => {
    const { data, error } = await client.rpc('search_cards_bulk', { p_names: noms, p_game: jeu })
    siErreur('search_cards_bulk', error)
    const lignes = (data ?? []) as {
      query: string
      name: string
      score: number
      owned: number
      price_eur: number | null
    }[]
    return enJson(noms.map((nom) => {
      const t = lignes.find((l) => l.query === nom)
      if (!t) return { nom, trouve: null }
      return { nom, trouve: t.name, exact: t.score >= 1, possede: t.owned, prix_eur: t.price_eur }
    }))
  })

  server.registerTool('editions_de_carte', {
    description: "Les éditions d'une carte (extension, numéro, langue, rareté, finitions, prix, " +
      'exemplaires possédés). Sert à désigner une édition pour ajouter_cartes ou retirer_cartes.',
    inputSchema: z.object({
      jeu,
      nom: z.string().min(1).max(200),
      extension: z.string().max(60).optional().describe("Code ou nom d'extension"),
      langue: z.string().max(8).optional().describe("Langue d'impression, ex. en, fr, ja"),
      page,
    }),
    annotations: LECTURE,
  }, async (a) => {
    const { data: trouvees, error: e1 } = await client.rpc('search_cards_bulk', { p_names: [a.nom], p_game: a.jeu })
    siErreur('search_cards_bulk', e1)
    const decision = deciderNom(a.nom, trouvees ?? [])
    if (decision.genre === 'introuvable') return enJson({ nom: a.nom, trouve: null })
    const carte = (trouvees ?? []).find((t: { query: string }) => t.query === a.nom)
    const { offset } = tranche(a.page, 60)
    const { data, error } = await client.rpc('card_printings', {
      p_oracle_id: carte.oracle_id,
      p_query: a.extension ?? null,
      p_lang: a.langue ?? null,
      p_limit: 60,
      p_offset: offset,
    })
    siErreur('card_printings', error)
    return enJson({ carte: carte.name, nom_exact: decision.genre === 'exacte', page: a.page, editions: data ?? [] })
  })

  server.registerTool('decks_suggeres', {
    description: "Decks du corpus confrontés à la collection : constructibles d'abord, puis par coût de " +
      "complétion. Chaque deck porte sa source et sa mention d'attribution, à citer. " +
      'missing_cost_eur est un plancher quand unpriced_cards est au-dessus de zéro.',
    inputSchema: z.object({
      jeu,
      format: z.enum(['commander', 'pauper', 'modern', 'constructed'])
        .describe('constructed pour les jeux autres que Magic'),
      manque_max: z.number().int().min(0).max(100).optional().describe('Cartes manquantes au plus'),
      cout_max: z.number().min(0).optional().describe('Coût de complétion maximal, en euros'),
      couleurs: z.array(couleur).max(5).optional(),
      couleurs_exclues: z.array(couleur).max(5).optional(),
      commandant: z.string().max(200).optional(),
      commandant_possede: z.boolean().default(false),
      resultats_max: z.number().int().min(1).max(50).default(20),
    }),
    annotations: LECTURE,
  }, async (a) => {
    const { data, error } = await client.rpc('deck_suggestions', {
      p_format: a.format,
      p_game: a.jeu,
      p_max_missing: a.manque_max ?? 100,
      p_max_results: a.resultats_max,
      p_max_cost: a.cout_max ?? null,
      p_colors: a.couleurs ?? null,
      p_banned_colors: a.couleurs_exclues ?? null,
      p_commander: a.commandant ?? null,
      p_owned_commander: a.commandant_possede,
    })
    siErreur('deck_suggestions', error)
    return enJson(data ?? [])
  })

  server.registerTool('cartes_manquantes', {
    description: "Ce qu'il manque pour compléter un deck de decks_suggeres : cartes, quantités, coût.",
    inputSchema: z.object({ deck_id: z.uuid() }),
    annotations: LECTURE,
  }, async ({ deck_id }) => {
    const { data, error } = await client.rpc('deck_missing_cards', { p_deck_id: deck_id })
    siErreur('deck_missing_cards', error)
    return enJson(data ?? [])
  })
}
