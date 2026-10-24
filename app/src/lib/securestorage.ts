// V6.1: sessão do Supabase guardada em armazenamento seguro (Keychain/Keystore) nos apps nativos.
// O SecureStore aceita ~2 KB por item; a sessão pode passar disso, então ela é gravada em partes
// (`<chave>.n` com o número de partes e `<chave>.0`, `<chave>.1`...). Na primeira leitura, a sessão antiga
// do AsyncStorage é copiada para cá e apagada de lá: ninguém é deslogado na atualização.
// Sem dependências do React Native aqui, para os testes rodarem no Node (tests/securestorage.test.ts).

export type KV = {
  getItem(key: string): Promise<string | null>;
  setItem(key: string, value: string): Promise<void>;
  removeItem(key: string): Promise<void>;
};

export const CHUNK = 1800;

export function chunkedStorage(secure: KV, legacy: KV | null): KV {
  async function count(key: string) {
    const n = Number(await secure.getItem(`${key}.n`));
    return Number.isInteger(n) && n > 0 ? n : 0;
  }
  async function clear(key: string) {
    const n = await count(key);
    await secure.removeItem(`${key}.n`);
    for (let i = 0; i < n; i++) await secure.removeItem(`${key}.${i}`);
  }
  async function write(key: string, value: string) {
    const parts: string[] = [];
    for (let i = 0; i < value.length; i += CHUNK) parts.push(value.slice(i, i + CHUNK));
    const old = await count(key);
    for (let i = 0; i < parts.length; i++) await secure.setItem(`${key}.${i}`, parts[i]);
    // O contador vai por último: uma gravação interrompida não deixa uma sessão pela metade visível.
    await secure.setItem(`${key}.n`, String(parts.length));
    for (let i = parts.length; i < old; i++) await secure.removeItem(`${key}.${i}`);
  }
  return {
    async getItem(key) {
      const n = await count(key);
      if (n > 0) {
        const parts: string[] = [];
        for (let i = 0; i < n; i++) {
          const p = await secure.getItem(`${key}.${i}`);
          if (p == null) return null;
          parts.push(p);
        }
        return parts.join('');
      }
      if (!legacy) return null;
      const old = await legacy.getItem(key);
      if (old == null) return null;
      await write(key, old);
      await legacy.removeItem(key);
      return old;
    },
    setItem: write,
    async removeItem(key) {
      await clear(key);
      if (legacy) await legacy.removeItem(key);
    },
  };
}
