// Vitrine da Central do Jogador V8.4 (só em desenvolvimento, sem login, DADOS SIMULADOS). Mostra os blocos da Central
// em cada estado (?s=ovr-up, ovr-down, ovr-neutro, primeira, avaliacao, urgente, nota-insuficiente, goleiro,
// uma-pelada, seis-peladas, offline, sem-pelada) para conferir o desenho no navegador e gerar as capturas. Nada aqui
// lê o banco.
import { useLocalSearchParams } from 'expo-router';
import { ScrollView, View } from 'react-native';

import type { Card as CardData } from '../lib/career';
import {
  AttentionBlock,
  BlockTitle,
  CardEvolution,
  CareerSummaryCard,
  CentralHeader,
  type HeroData,
  LastGameCard,
  MyPeladasBlock,
  NextRoundCard,
  Notice,
  PeladaSelector,
  UrgentVote,
  type VoteItem,
} from '../lib/central';
import type { LastGameRow, Pelada, PeladaRating } from '../lib/centraldata';
import { colors, layout as L } from '../lib/theme';
import { Button, Card, EmptyState, Sub } from '../lib/ui';
import { myPeladasSummary, splitAttention } from '../lib/v84logic';

const card: Omit<CardData, 'id'> = {
  position: 'midfielder',
  position_code: 'MEI',
  finishing: 0,
  assisting: 0,
  attendance: 0,
  winning: 0,
  peer_rating: 0,
  overall: 82.2,
  tier: 'ouro',
  is_provisional: false,
  matches_played: 18,
  formula_version: 2,
  atu: 84.2,
  est: 86.9,
  peq: 74.1,
  res: 78.3,
  dis: 88.5,
  ovr_display: 82,
};
const mk = (id: string, name: string, role: Pelada['role'] = 'player'): Pelada => ({
  id,
  name,
  crest_path: null,
  role,
  membership_id: `m-${id}`,
  position: 'midfielder',
  position_code: 'MEI',
  is_primary: id === 'a',
  drafts: 0,
  setup: null,
});
const peladas = [mk('a', 'Pelada de Quinta', 'admin'), mk('b', 'Resenha FC'), mk('c', 'Racha dos Amigos'), mk('d', 'Society da Firma'), mk('e', 'Futebol de Domingo'), mk('f', 'Várzea Premium')];
const hero: HeroData = {
  name: 'Rafael Abreu',
  avatarPath: null,
  peladaName: 'Pelada de Quinta',
  crestPath: null,
  position: 'MEI',
  card,
  seasonName: 'Temporada 2026',
  seasonStart: '2026-01-01',
};
const game: LastGameRow = {
  match_id: 'm',
  played_at: '2026-10-22T22:00:00Z',
  team_a_name: 'Azul',
  team_b_name: 'Branco',
  team_a_score: 5,
  team_b_score: 3,
  my_team: 'A',
  position: 'MEI',
  goals: 2,
  assists: 0,
  red_cards: 0,
  hard_saves: null,
  final_rating: 8.25,
  has_valid_rating: true,
  rating_session_status: 'published',
  legacy_finalized: false,
};
const vote = (mins: number): VoteItem => ({
  match_id: 'v',
  pelada_id: 'a',
  pelada_name: 'Pelada de Quinta',
  closes_at: new Date(Date.now() + mins * 60000).toISOString(),
  team_a_name: 'Azul',
  team_b_name: 'Branco',
  team_a_score: 5,
  team_b_score: 3,
  rated: 6,
  total: 11,
  started: true,
  v2: true,
});
const noop = () => {};

// V6.1: fora do __DEV__ a rota existe no bundle, mas não mostra nada (antes abria com login em produção).
export default function DevCentralRoute() {
  return __DEV__ ? <DevCentral /> : null;
}

function DevCentral() {
  const { s = 'ovr-up' } = useLocalSearchParams<{ s?: string }>();
  const first = s === 'primeira';
  const delta = s === 'ovr-down' ? -3 : s === 'ovr-neutro' ? 0 : s === 'ovr-up' ? 2 : null;
  const evaluating = s === 'avaliacao';
  const h: HeroData = evaluating ? { ...hero, card: { ...card, tier: 'prata', is_provisional: true, matches_played: 3, ovr_display: null } } : hero;
  const rating: PeladaRating = evaluating
    ? { rating: { eligible: false, matches_played: 3, ovr: null, tier: null, position: 'MEI' }, delta: null }
    : { rating: { eligible: true, matches_played: 18, ovr: s === 'ovr-down' ? 79 : 82, tier: 'ouro', position: 'MEI' }, delta: first ? null : delta };
  const ovr = evaluating ? null : s === 'ovr-down' ? 79 : 82;
  const gk = s === 'goleiro';
  const g: LastGameRow = gk
    ? { ...game, position: 'GOL', hard_saves: 4, goals: 0 }
    : s === 'nota-insuficiente'
      ? { ...game, final_rating: null, has_valid_rating: false }
      : game;
  const list = s === 'uma-pelada' ? peladas.slice(0, 1) : s === 'seis-peladas' ? peladas : peladas.slice(0, 3);
  const att = splitAttention([
    { key: 'v', rank: 1, title: 'Votação aberta: Azul 5 x 3 Branco', detail: 'Faltam 5h20 · você avaliou 2 de 11', action: 'Continuar', tone: 'blue' as const, onPress: noop },
    { key: 'o', rank: 1, title: 'Votação aberta em Resenha FC', detail: 'Faltam 1d 3h', action: 'Votar', tone: 'blue' as const, onPress: noop },
    { key: 'c', rank: 2, title: 'Você tem um convite para aceitar', detail: 'Veja a pelada e entre.', action: 'Ver', tone: 'blue' as const, onPress: noop },
    { key: 'p', rank: 4, title: 'Coloque uma foto no seu perfil', detail: 'Ela aparece na sua carta.', action: 'Perfil', tone: 'gold' as const, onPress: noop },
  ]);
  const sum = myPeladasSummary(list, 'a');

  return (
    <ScrollView style={{ backgroundColor: colors.white }} contentContainerStyle={{ alignItems: 'center', paddingTop: 16, paddingBottom: 32 }}>
      <View style={{ width: '100%', maxWidth: L.maxWidth, paddingHorizontal: L.gutter, gap: L.gap }}>
        <CentralHeader name="Rafael Abreu" avatarPath={null} position={s === 'sem-pelada' ? null : 'MEI'} ovr={s === 'sem-pelada' ? null : ovr} unread={s !== 'ovr-neutro'} onProfile={noop} onBell={noop} />
        <Sub>Dados simulados · estado: {s}</Sub>
        {s === 'offline' && <Notice tone="warn">Sem conexão. Você vê os dados salvos neste aparelho (atualizado há 12 min). Nada pode ser alterado até reconectar.</Notice>}
        {s === 'sem-pelada' ? (
          <Card>
            <EmptyState
              title="Sua carreira começa numa pelada"
              hint="Crie a pelada da sua turma ou entre com o convite que recebeu. A carta ganha o OVR depois de cinco partidas disputadas e publicadas.">
              <Button title="Criar pelada" onPress={noop} />
              <Button title="Entrar com convite" kind="secondary" onPress={noop} />
            </EmptyState>
          </Card>
        ) : (
          <>
            <PeladaSelector peladas={list} activeId="a" onSelect={async () => {}} />
            {s === 'urgente' && <UrgentVote vote={vote(42)} offset={0} onPress={noop} />}
            <CardEvolution data={h} rating={rating} loading={false} stale={s === 'offline'} onCareer={noop} />
            <View style={{ gap: 4 }}>
              <BlockTitle>Próxima Rodada</BlockTitle>
              <NextRoundCard
                round={{ lineup_id: 'l', pelada_id: 'a', pelada_name: 'Pelada de Quinta', label: 'Rodada 3', team_name: 'Azul', opponent_name: 'Branco' }}
                more={1}
                stale={s === 'offline'}
                onPress={noop}
              />
            </View>
            <View style={{ gap: 4 }}>
              <BlockTitle>Último Jogo</BlockTitle>
              <LastGameCard game={g} stale={s === 'offline'} onPress={noop} />
            </View>
            <View style={{ gap: 4 }}>
              <BlockTitle>Resumo da Carreira</BlockTitle>
              <CareerSummaryCard position={gk ? 'GOL' : 'MEI'} totals={{ matches_played: 42, wins: 23, draws: 6, losses: 13, goals: 27, assists: 15 }} stale={s === 'offline'} onPress={noop} />
            </View>
            <AttentionBlock {...att} stale={s === 'offline'} />
            {list.length >= 2 && <MyPeladasBlock shown={sum.shown} seeAll={sum.seeAll} onOpen={noop} onSeeAll={noop} />}
          </>
        )}
      </View>
    </ScrollView>
  );
}
