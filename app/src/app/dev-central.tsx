// Vitrine da Central do Jogador 2.0 (só em desenvolvimento, sem login, DADOS SIMULADOS). Mostra os blocos da Central
// em cada estado (?s=ovr-up, ovr-down, ovr-neutro, avaliacao, urgente, insuficiente, nao-jogou, sem-pelada) para
// conferir o desenho no navegador e gerar as capturas. Nada aqui lê o banco.
import { useLocalSearchParams } from 'expo-router';
import { ScrollView, View } from 'react-native';

import type { Card as CardData } from '../lib/career';
import {
  BlockTitle,
  CareerHero,
  CareerRecap,
  CentralHeader,
  HeroData,
  LastGame,
  LastGameData,
  NextRound,
  PeladaSwitcher,
  PendingList,
  UrgentVote,
  VoteItem,
} from '../lib/central';
import { colors } from '../lib/theme';
import { Button, Card, EmptyState, Sub } from '../lib/ui';

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
const peladas = [
  { id: 'a', name: 'Pelada de Quinta', crest_path: null, role: 'admin' },
  { id: 'b', name: 'Resenha FC', crest_path: null, role: 'player' },
];
const hero: HeroData = {
  name: 'Rafael Abreu',
  avatarPath: null,
  peladaName: 'Pelada de Quinta',
  crestPath: null,
  position: 'MEI',
  card,
  seasonName: 'Temporada 2026',
  seasonStart: '2026-01-01',
  season: { matches_played: 18, goals: 11, assists: 7 },
};
const game: LastGameData = {
  match_id: 'm',
  played_at: '2026-10-22T22:00:00Z',
  status: 'finalized',
  team_a_name: 'Azul',
  team_b_name: 'Branco',
  team_a_score: 5,
  team_b_score: 3,
  me: { team: 'A', goals: 2, assists: 1 },
  rating: { kind: 'rated', value: 8.25 },
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
  const delta = s === 'ovr-down' ? -3 : s === 'ovr-neutro' ? 0 : s === 'ovr-up' ? 2 : null;
  const evaluating = s === 'avaliacao';
  const h: HeroData = evaluating
    ? {
        ...hero,
        card: { ...card, tier: 'prata', is_provisional: true, matches_played: 3, ovr_display: null },
        season: { matches_played: 3, goals: 1, assists: 2 },
      }
    : s === 'sem-carta'
      ? { ...hero, card: null, season: { matches_played: 1, goals: 0, assists: 0 } }
      : hero;
  const rating = evaluating
    ? { rating: { eligible: false, matches_played: 3, ovr: null, tier: null, position: 'MEI' }, delta: null }
    : s === 'sem-carta'
      ? { rating: { eligible: false, matches_played: 1, ovr: null, tier: null, position: 'MEI' }, delta: null }
      : { rating: { eligible: true, matches_played: 18, ovr: s === 'ovr-down' ? 79 : 82, tier: 'ouro' as const, position: 'MEI' }, delta };
  const g: LastGameData =
    s === 'insuficiente'
      ? { ...game, rating: { kind: 'insufficient' } }
      : s === 'nao-jogou'
        ? { ...game, me: null, rating: { kind: 'none' } }
        : s === 'urgente'
          ? { ...game, status: 'finalized', rating: { kind: 'pending' } }
          : game;

  return (
    <ScrollView style={{ backgroundColor: colors.white }} contentContainerStyle={{ padding: 20, paddingTop: 16, gap: 12 }}>
      <CentralHeader name="Rafael Abreu" avatarPath={null} onProfile={noop} onBell={noop} />
      <Sub>Dados simulados · estado: {s}</Sub>
      {s === 'sem-pelada' ? (
        <Card>
          <EmptyState
            title="Sua carreira começa numa pelada"
            hint="Crie a pelada da sua turma ou entre com o convite que recebeu. Depois de cinco partidas, sua carta ganha o OVR.">
            <Button title="Criar pelada" onPress={noop} />
            <Button title="Entrar com convite" kind="secondary" onPress={noop} />
          </EmptyState>
        </Card>
      ) : (
        <>
          <PeladaSwitcher peladas={s === 'uma-pelada' ? peladas.slice(0, 1) : peladas} selected="a" onSelect={noop} />
          {s === 'urgente' && <UrgentVote vote={vote(42)} offset={0} onPress={noop} />}
          <CareerHero data={h} rating={rating} ratingLoading={false} onCareer={noop} />
          <BlockTitle>Pendências</BlockTitle>
          <PendingList
            items={[
              ...(s === 'urgente'
                ? []
                : [
                    {
                      key: 'v',
                      title: 'Votação aberta: Azul 5 x 3 Branco',
                      detail: 'Faltam 5h20 · você avaliou 2 de 11',
                      action: 'Continuar',
                      tone: 'blue' as const,
                      onPress: noop,
                    },
                  ]),
              { key: 'o', title: 'Votação aberta em Resenha FC', detail: 'Faltam 1d 3h', action: 'Abrir', tone: 'blue', onPress: noop },
              {
                key: 'p',
                title: 'Coloque uma foto no seu perfil',
                detail: 'Ela aparece na sua carta.',
                action: 'Perfil',
                tone: 'gold',
                onPress: noop,
              },
            ]}
          />
          <BlockTitle>Próxima rodada</BlockTitle>
          <NextRound
            round={{ lineup_id: 'l', pelada_id: 'a', pelada_name: 'Pelada de Quinta', label: 'Rodada 3', team_name: 'Azul', opponent_name: 'Branco' }}
            more={1}
            onPress={noop}
          />
          <BlockTitle>Último jogo</BlockTitle>
          <LastGame game={g} onPress={noop} />
          <BlockTitle>Resumo da carreira</BlockTitle>
          <CareerRecap totals={{ matches_played: 42, wins: 23, goals: 27, assists: 15 }} conquests={6} hiddenSeasons={0} onPress={noop} />
          <View style={{ height: 12 }} />
        </>
      )}
    </ScrollView>
  );
}
