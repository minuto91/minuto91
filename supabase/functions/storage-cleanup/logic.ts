// Regras da limpeza de imagens órfãs, sem rede (testadas em supabase/local_db/storage_logic.test.mjs).
// A24: a listagem pagina por completo, tanto as pastas do bucket quanto os arquivos de cada pasta (antes os
// arquivos de uma pasta eram lidos só até 1.000). A lista inteira é montada antes de apagar qualquer coisa,
// para a paginação não pular itens.

export type Entry = { name: string; id?: string | null; created_at?: string | null };
export type Lister = (prefix: string, offset: number, limit: number) => Promise<Entry[]>;

/** Todas as entradas de um prefixo, página por página, até vir uma página incompleta. */
export async function listAll(list: Lister, prefix: string, page: number): Promise<Entry[]> {
  const out: Entry[] = [];
  for (let offset = 0; ; offset += page) {
    const batch = await list(prefix, offset, page);
    out.push(...batch);
    if (batch.length < page) return out;
  }
}

/** Caminhos <pasta>/<arquivo> com mais de minAgeMs. Pastas não têm id; arquivos têm. */
export async function candidates(list: Lister, page: number, cutoffMs: number): Promise<string[]> {
  const result: string[] = [];
  const folders = (await listAll(list, '', page)).filter((f) => !f.id);
  for (const folder of folders) {
    for (const f of await listAll(list, folder.name, page)) {
      const created = Date.parse(f.created_at ?? '');
      if (f.id && Number.isFinite(created) && created < cutoffMs) result.push(`${folder.name}/${f.name}`);
    }
  }
  return result;
}
