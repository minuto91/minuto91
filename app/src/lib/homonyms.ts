// REV-046: nomes iguais são permitidos. Para diferenciar: foto e posição; se ainda houver empate, um
// identificador curto e discreto (nunca na carta). As relações usam sempre o id interno.
import { normalizeName } from './search';

type Person = { id: string; name: string; position?: string | null; hasPhoto?: boolean };

/** id -> sufixo discreto (ex.: "#3f2a") só para quem continua ambíguo depois de foto e posição. */
export function disambiguators(list: Person[]): Record<string, string> {
  const groups = new Map<string, Person[]>();
  for (const p of list) {
    const k = `${normalizeName(p.name)}|${p.position ?? ''}|${p.hasPhoto ? 'f' : ''}`;
    groups.set(k, [...(groups.get(k) ?? []), p]);
  }
  const out: Record<string, string> = {};
  for (const g of groups.values()) if (g.length > 1) for (const p of g) out[p.id] = `#${p.id.replace(/-/g, '').slice(0, 4)}`;
  return out;
}
