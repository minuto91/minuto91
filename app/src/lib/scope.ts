// Escopo do beta fechado (BETA-02). EXPO_PUBLIC_BETA_SCOPE=core esconde, só no app, o que está fora do PRD v2.5
// (seção 3 e 10.4): Financeiro, Sorteio, Escalações, Craque da Temporada, Prêmios da temporada (Artilheiro, Maestro,
// Luva de Ouro), Paredão do Mês, Personalizar Central e o guia de Cards e premiações. Nada é apagado: telas, migrações
// e dados continuam; o servidor segue calculando. Com a variável ausente (ou diferente de "core") o app fica como era.
// Função pura, sem React nem Expo (testada em tests/scope.test.ts). A variável é lida na hora do build (EXPO_PUBLIC_*).

export const BETA_CORE = process.env.EXPO_PUBLIC_BETA_SCOPE === 'core';

/** Primeiro segmento de rota (ou prefixo "pelada/[id]/...") que o escopo core esconde. */
const HIDDEN_PELADA_SCREENS = ['financeiro', 'sorteio', 'escalacoes', 'composicao', 'craque-temporada', 'premios-temporada'] as const;
const HIDDEN_ROOT_SCREENS = ['personalizar-central', 'guia-cards'] as const;

/** Tipos de troféu fora do PRD (Sala de Troféus, Meus Prêmios, Carreira). */
export const OUT_OF_SCOPE_TROPHIES = ['monthly_goalkeeper', 'season_craque', 'season_top_scorer', 'season_maestro', 'season_golden_glove'] as const;

/** Segmentos de rota como o expo-router entrega em useSegments() (ex.: ['pelada', '[id]', 'financeiro', 'index']). */
export function isRouteHidden(segments: readonly string[], core: boolean = BETA_CORE): boolean {
  if (!core) return false;
  const first = segments.find((s) => !(s.startsWith('(') && s.endsWith(')')));
  if (!first) return false;
  if ((HIDDEN_ROOT_SCREENS as readonly string[]).includes(first)) return true;
  if (first === 'pelada') {
    const idx = segments.indexOf('[id]');
    const screen = idx >= 0 ? segments[idx + 1] : segments[1];
    return !!screen && (HIDDEN_PELADA_SCREENS as readonly string[]).includes(screen);
  }
  return false;
}

/** Rotas de desenvolvimento só existem em __DEV__: em build de produção qualquer "dev-*" é recusada. */
export function isDevRouteBlocked(segments: readonly string[], dev: boolean): boolean {
  if (dev) return false;
  const first = segments.find((s) => !(s.startsWith('(') && s.endsWith(')')));
  return !!first && first.startsWith('dev-');
}

export const isTrophyHidden = (t: string, core: boolean = BETA_CORE) => core && (OUT_OF_SCOPE_TROPHIES as readonly string[]).includes(t);

/** Mesma convenção de rota, para caminhos textuais ("/pelada/<uuid>/financeiro") vindos de avisos e links. */
export function isPathHidden(path: string, core: boolean = BETA_CORE): boolean {
  if (!core) return false;
  const parts = path.split('?')[0].split('/').filter(Boolean);
  if (!parts.length) return false;
  if ((HIDDEN_ROOT_SCREENS as readonly string[]).includes(parts[0])) return true;
  return parts[0] === 'pelada' && !!parts[2] && (HIDDEN_PELADA_SCREENS as readonly string[]).includes(parts[2]);
}
