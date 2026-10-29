// Vitrine da V8.7: só em desenvolvimento. Mostra Sala (contadores), Meus Prêmios, a tela dos prêmios da temporada (com a
// exceção da Luva) e as artes da retrospectiva, com DADOS SIMULADOS. Nunca lê o Supabase. Não é teste de integração.
import { useState } from 'react';
import { View } from 'react-native';

import { SharePanel } from '../lib/arts';
import { MyAwardsList } from '../lib/myawards';
import { OfficialRetro, RetroArt } from '../lib/retroarts';
import { AwardsState, AwardsView } from '../lib/seasonawards';
import { Text } from '../lib/text';
import { colors } from '../lib/theme';
import { TROPHIES, TrophyArt } from '../lib/trophies';
import { Chips, Screen, Section, Sub, Title } from '../lib/ui';
import { SeasonTitle, showMyAwards } from '../lib/v87logic';

const W = (id: string, name: string, value: number | string, shared = false) => ({ membership_id: id, name, avatar_path: null, value, is_shared: shared });
const TITLES: SeasonTitle[] = [
  { id: '1', award_type: 'season_craque', season_id: 's27', season_name: 'Temporada 2027', year: 2027, starts_on: '2027-01-01', is_shared: false, pelada_id: 'p1', pelada_name: 'Resenha FC' },
  { id: '2', award_type: 'season_golden_glove', season_id: 's27', season_name: 'Temporada 2027', year: 2027, starts_on: '2027-01-01', is_shared: true, pelada_id: 'p1', pelada_name: 'Resenha FC' },
  { id: '3', award_type: 'season_top_scorer', season_id: 's26', season_name: 'Temporada 2026', year: 2026, starts_on: '2026-01-01', is_shared: false, pelada_id: 'p1', pelada_name: 'Resenha FC' },
  { id: '4', award_type: 'season_maestro', season_id: 's25', season_name: 'Temporada 2025', year: 2025, starts_on: '2025-01-01', is_shared: false, pelada_id: 'p2', pelada_name: 'Pelada do Trabalho' },
];
const GK = (n: number) => ({ membership_id: `g${n}`, name: `Goleiro ${n}`, gk_matches: 3 + n, ref: 70 + n });
const BASE: AwardsState = {
  season_id: 's26', ready: true, is_admin: false, ref_note: 'A REF da Luva de Ouro é a REF oficial no encerramento: janela móvel das últimas 20 partidas do goleiro, que pode incluir temporadas anteriores.',
  categories: {
    top_scorer: { status: 'published', version: 1, basis: 'normal', winners: [W('a', 'Rafael Silva', 6, true), W('b', 'Bruno Costa', 6, true)] },
    maestro: { status: 'published', version: 1, basis: 'normal', winners: [W('c', 'Diego Lima', 4)] },
    golden_glove: { status: 'published', version: 2, basis: 'normal', winners: [W('d', 'Caio Mendes', '76.0585')] },
  },
};
const SCENES: Record<string, AwardsState> = {
  'Publicado (membro)': BASE,
  'Luva por exceção': { ...BASE, categories: { ...BASE.categories, golden_glove: { status: 'published', version: 2, basis: 'exception', winners: [W('d', 'Caio Mendes', '73.5')] } } },
  'Sem goleiro elegível (admin)': {
    ...BASE, is_admin: true,
    categories: { ...BASE.categories, golden_glove: { status: 'awaiting_exception', version: 1, basis: 'normal', winners: [] } },
    golden_glove_exception: { available: true, active: null, floor_matches: 3, candidates: [GK(0), GK(1)] },
  },
  'Aguardando (membro)': { ...BASE, categories: { ...BASE.categories, golden_glove: { status: 'pending', version: 1, basis: 'normal', winners: [] } } },
  'Sem vencedores': { ...BASE, categories: { top_scorer: { status: 'no_winner', version: 1, basis: 'normal', winners: [] }, maestro: { status: 'no_winner', version: 1, basis: 'normal', winners: [] }, golden_glove: { status: 'no_winner', version: 1, basis: 'normal', winners: [] } } },
  'Em andamento': { ...BASE, ready: false, categories: {} },
};
const RETRO = {
  version: 1, season: { id: 's26', name: 'Temporada 2026', starts_on: '2026-01-01', ends_on: '2026-12-31' }, matches: 41, goals: 187,
  biggest_win: null, most_goals: null, scorers: [], assisters: [], presence: [], craques: [], selection_leaders: [], kings: [], records: null,
  me: { matches: 30, wins: 17, draws: 5, losses: 8, goals: 12, assists: 7, craque: 2, kings: 1 },
  season_awards: BASE.categories,
} as unknown as OfficialRetro;
const MINE = { ...RETRO, season_awards: { ...BASE.categories, top_scorer: { status: 'published', version: 1, basis: 'normal', winners: [W('me', 'Rafael Silva', 6, true), W('b', 'Bruno Costa', 6, true)] } } } as unknown as OfficialRetro;

const OTHER = ['Sala e Meus Prêmios', 'Artes'];

export default function DevV87() {
  const [scene, setScene] = useState(Object.keys(SCENES)[0]);
  if (!__DEV__) return null;
  const all = [...Object.keys(SCENES), ...OTHER];
  if (!OTHER.includes(scene)) {
    return (
      <AwardsView state={SCENES[scene]} seasons={all.map((k) => ({ id: k, name: k }))} seasonId={scene} onSeason={setScene} busy={false} msg={null} onGrant={() => {}} onRevoke={() => {}} />
    );
  }
  return (
    <Screen>
      <Title>V8.7 · vitrine (dados simulados)</Title>
      <Chips options={all.map((k) => ({ value: k, label: k }))} value={scene} onChange={setScene} />
      {scene === 'Sala e Meus Prêmios' && (
        <>
          <Section first>Sala de Troféus (só contadores)</Section>
          <View style={{ flexDirection: 'row', flexWrap: 'wrap', justifyContent: 'center', gap: 8 }}>
            {TROPHIES.map((t) => (
              <View key={t.type} style={{ alignItems: 'center', width: 96 }}>
                <TrophyArt type={t.type} size={72} dim={false} />
                <Text style={{ fontSize: 11, textAlign: 'center', color: colors.deepBlue, fontWeight: '700' }}>{t.label}</Text>
              </View>
            ))}
          </View>
          <Section>Meus Prêmios (Geral, várias peladas)</Section>
          {showMyAwards(TITLES) && <MyAwardsList items={TITLES} withOrigin />}
          <Section>Meus Prêmios (uma pelada)</Section>
          <MyAwardsList items={TITLES.slice(0, 3)} withOrigin={false} />
          <Sub>Sem títulos: o bloco não aparece.</Sub>
        </>
      )}
      {scene === 'Artes' && (
        <>
          <Section first>P07 · coletiva</Section>
          <SharePanel label="P07" fileName="p07" title="Prêmios da temporada"><RetroArt id="P07" retro={RETRO} peladaName="Resenha FC" crestPath={null} /></SharePanel>
          <Section>I06 · individual (com título compartilhado)</Section>
          <SharePanel label="I06" fileName="i06" title="Meus títulos"><RetroArt id="I06" retro={MINE} peladaName="Resenha FC" crestPath={null} playerName="Rafael Silva" myMembershipId="me" myPhotoPath={null} /></SharePanel>
        </>
      )}
    </Screen>
  );
}
