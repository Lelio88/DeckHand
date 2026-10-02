/**
 * documentation_test.ts — La page publique `app/web/assistant.html` décrit les
 * outils que le serveur publie vraiment, ni plus ni moins, et les consignes du
 * serveur y renvoient l'agent.
 *
 * Une documentation qui ment est pire qu'aucune : un agent qui y lit un outil
 * disparu l'appellera, un outil absent de la page ne sera pas trouvé par qui la
 * lit d'abord. La table est donc éprouvée contre l'enregistrement réel, sur un
 * serveur factice qui note les noms.
 *
 *   deno test --allow-read supabase/functions/mcp
 */
import { assertEquals, assertStringIncludes } from '@std/assert'
import type { McpServer } from '@modelcontextprotocol/server'
import type { SupabaseClient } from '@supabase/supabase-js'
import type { Base } from './base.ts'
import { CONSIGNES, DOCUMENTATION } from './consignes.ts'
import { enregistrerEcritures } from './ecriture.ts'
import { enregistrerLectures } from './lecture.ts'

const PAGE = new URL('../../../app/web/assistant.html', import.meta.url)

function outilsEnregistres(): string[] {
  const noms: string[] = []
  const serveur = { registerTool: (nom: string) => noms.push(nom) } as unknown as McpServer
  enregistrerLectures(serveur, {} as SupabaseClient)
  enregistrerEcritures(serveur, {} as Base)
  return noms.sort()
}

function outilsDocumentes(html: string): string[] {
  return [...html.matchAll(/<code class="outil">([a-z_]+)<\/code>/g)].map((m) => m[1]).sort()
}

Deno.test('la page documente exactement les outils du serveur', async () => {
  const html = await Deno.readTextFile(PAGE)
  assertEquals(outilsDocumentes(html), outilsEnregistres())
})

Deno.test("la page porte l'adresse du serveur, injectée à la publication", async () => {
  const html = await Deno.readTextFile(PAGE)
  assertStringIncludes(html, '__SUPABASE_URL__/functions/v1/mcp')
})

Deno.test('les consignes du serveur renvoient à la page', () => {
  assertEquals(DOCUMENTATION, 'https://deckhand.heianenterprise.com/assistant.html')
  assertStringIncludes(CONSIGNES, DOCUMENTATION)
})
