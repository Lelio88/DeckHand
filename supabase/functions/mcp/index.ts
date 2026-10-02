/**
 * index.ts — Le serveur MCP de DeckHand : ce qu'un assistant IA (claude.ai,
 * Claude Code, Cursor…) peut lire et écrire dans la collection d'un
 * utilisateur qui l'a autorisé. Edge Function Supabase, transport HTTP.
 *
 * Choix non évidents :
 * - **Le modèle officiel de Supabase** : `withOAuthProtectedResource` publie la
 *   découverte OAuth (RFC 9728) et répond 401 avec `WWW-Authenticate` à un
 *   client sans jeton ; `withSupabase({ auth: 'user' })` vérifie le jeton et
 *   rend un client borné à l'utilisateur. Le serveur d'autorisation est
 *   Supabase Auth lui-même : DeckHand n'en écrit aucun.
 * - **Un serveur neuf par requête** : une Edge Function ne garde rien d'une
 *   requête à l'autre, et le client de la base dépend du jeton de chacune.
 * - **Une traduction mince, sans logique métier** : chaque outil appelle une
 *   fonction SQL de l'application. Le calcul reste en base, la RLS et la garde
 *   de l'assistant (`20261002100000_garde_assistant.sql`) s'appliquent d'elles-
 *   mêmes.
 * - **`verify_jwt = false`** dans `supabase/config.toml` (et au déploiement) :
 *   la passerelle refuserait sinon la découverte, qui répond à un client encore
 *   sans jeton. La vérification est faite ici, par `withSupabase`.
 *
 * Invariant : seul `ctx.supabase` (borné à l'utilisateur) est utilisé, jamais
 * `ctx.supabaseAdmin`.
 *
 * Détails : `docs/mcp-architecture.md`.
 */
import '@supabase/functions-js/edge-runtime.d.ts'
import { createMcpHandler, McpServer } from '@modelcontextprotocol/server'
import { pipeline } from '@supabase/middleware'
import { withOAuthProtectedResource, withSupabase } from '@supabase/server'
import type { SupabaseClient } from '@supabase/supabase-js'
import { baseSupabase } from './base.ts'
import { CONSIGNES } from './consignes.ts'
import { enregistrerEcritures } from './ecriture.ts'
import { enregistrerLectures } from './lecture.ts'

function construireServeur(client: SupabaseClient): McpServer {
  const server = new McpServer({ name: 'deckhand', version: '1.0.0' }, { instructions: CONSIGNES })
  enregistrerLectures(server, client)
  enregistrerEcritures(server, baseSupabase(client))
  return server
}

Deno.serve(
  pipeline(
    [withOAuthProtectedResource(), withSupabase({ auth: 'user' })],
    (req, { supabase }) => createMcpHandler(() => construireServeur(supabase)).fetch(req),
  ),
)
