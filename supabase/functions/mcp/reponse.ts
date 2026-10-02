/**
 * reponse.ts — La forme commune des réponses d'outil : un texte JSON compact,
 * que l'agent lit comme une donnée.
 */
import type { CallToolResult } from '@modelcontextprotocol/server'

export function enJson(valeur: unknown): CallToolResult {
  return { content: [{ type: 'text', text: JSON.stringify(valeur) }] }
}

/** Une erreur de la base devient une erreur d'outil, lisible par l'agent. */
export function siErreur(fonction: string, erreur: { message: string } | null): void {
  if (erreur) throw new Error(`${fonction} : ${erreur.message}`)
}
