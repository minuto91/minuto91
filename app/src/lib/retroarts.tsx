// REV-020: artes da retrospectiva oficial. Seis coletivas (P01–P06) e cinco individuais (I01–I05), cada uma com
// composição própria para Story (1080 × 1920: coluna vertical, números grandes) e Feed (1080 × 1350: grade em duas
// colunas, mais compacta) — nunca um recorte da outra. Branco, azul e dourado. Só dados oficiais da versão gerada.
import { View } from 'react-native';
import Svg, { Polyline } from 'react-native-svg';

import { Header, useArtFormat } from './arts';
import { Avatar } from './avatar';
import { Text } from './text';
import { colors } from './theme';
import { TrophyArt } from './trophies';
import { AWARD_CATEGORIES, CATEGORY_TYPE, myAwardTitles, SEASON_AWARD_LABEL, SeasonAwardsData, SeasonCategory, seasonTag, sharedLabel, statText } from './v87logic';

export { AWARD_CATEGORIES, myAwardTitles };
export type { AwardWinner, SeasonAwardsData } from './v87logic';

export type RetroTop = { membership_id: string; name: string; value: number; rank?: number };
export type RetroMatchRow = { id: string; played_at: string; team_a_name: string; team_b_name: string; team_a_score: number; team_b_score: number };
// V8.7: vencedores publicados dos prêmios de temporada (só a versão corrente; foto só se a pessoa pode ser vista na pelada).

export type OfficialRetro = {
  season_awards?: SeasonAwardsData;
  version: number;
  season: { id: string; name: string; starts_on: string; ends_on: string };
  matches: number;
  goals: number;
  biggest_win: RetroMatchRow | null;
  most_goals: RetroMatchRow | null;
  scorers: RetroTop[];
  assisters: RetroTop[];
  presence: RetroTop[];
  craques: RetroTop[];
  selection_leaders: RetroTop[];
  kings: { month: string; names: string[] }[];
  records: Record<string, { value: number | null; membership_ids: string[] | null } | unknown> | null;
  me: { matches: number; wins: number; draws: number; losses: number; goals: number; assists: number; craque: number; kings: number } | null;
};

export const COLLECTIVE = [
  { id: 'P01', label: 'Capa' },
  { id: 'P02', label: 'Números' },
  { id: 'P03', label: 'Estrelas' },
  { id: 'P04', label: 'Seleção da Rodada' },
  { id: 'P05', label: 'Partidas memoráveis' },
  { id: 'P07', label: 'Prêmios da temporada' },
  { id: 'P06', label: 'Encerramento' },
] as const;
export const INDIVIDUAL = [
  { id: 'I01', label: 'Temporada e carta' },
  { id: 'I02', label: 'Estatísticas' },
  { id: 'I03', label: 'Evolução do OVR' },
  { id: 'I04', label: 'Conquistas' },
  { id: 'I06', label: 'Meus títulos da temporada' },
  { id: 'I05', label: 'Resumo' },
] as const;
export type ArtId = (typeof COLLECTIVE)[number]['id'] | (typeof INDIVIDUAL)[number]['id'];

const blue = colors.blue;
const gold = colors.gold;

function Big({ value, label, accent }: { value: string; label: string; accent?: boolean }) {
  const story = useArtFormat() === 'story';
  return (
    <View style={{ alignItems: 'center', flexBasis: story ? '100%' : '48%', paddingVertical: story ? 6 : 4 }}>
      <Text style={{ fontSize: story ? 46 : 34, lineHeight: story ? 52 : 40, fontWeight: '900', color: accent ? colors.darkGold : blue }}>{value}</Text>
      <Text style={{ fontSize: 12, fontWeight: '700', letterSpacing: 0.6, color: colors.muted }}>{label.toUpperCase()}</Text>
    </View>
  );
}

function Grid({ children }: { children: React.ReactNode }) {
  const story = useArtFormat() === 'story';
  return (
    <View style={{ flexDirection: story ? 'column' : 'row', flexWrap: 'wrap', justifyContent: 'space-between', rowGap: story ? 4 : 8 }}>
      {children}
    </View>
  );
}

function Podium({ title, list, unit }: { title: string; list: RetroTop[]; unit: string }) {
  const story = useArtFormat() === 'story';
  const top = list.slice(0, story ? 3 : 2);
  if (top.length === 0) return null;
  return (
    <View style={{ gap: 4, flexBasis: story ? '100%' : '48%' }}>
      <Text style={{ fontSize: 11, fontWeight: '800', letterSpacing: 0.8, color: colors.darkGold, textAlign: story ? 'center' : 'left' }}>
        {title.toUpperCase()}
      </Text>
      {top.map((t, i) => (
        <View key={t.membership_id} style={{ flexDirection: 'row', alignItems: 'baseline', gap: 6, justifyContent: story ? 'center' : 'flex-start' }}>
          <Text style={{ fontSize: i === 0 ? 17 : 14, fontWeight: i === 0 ? '800' : '600', color: colors.ink, flexShrink: 1 }} numberOfLines={1}>
            {t.name}
          </Text>
          <Text style={{ fontSize: 13, fontWeight: '800', color: blue }}>{`${t.value} ${unit}`}</Text>
        </View>
      ))}
    </View>
  );
}

function MatchLine({ label, m }: { label: string; m: RetroMatchRow | null }) {
  if (!m) return null;
  return (
    <View style={{ alignItems: 'center', gap: 2 }}>
      <Text style={{ fontSize: 11, fontWeight: '800', letterSpacing: 0.8, color: colors.darkGold }}>{label.toUpperCase()}</Text>
      <Text style={{ fontSize: 15, fontWeight: '700', color: colors.ink, textAlign: 'center' }} numberOfLines={2}>
        {`${m.team_a_name} ${m.team_a_score}–${m.team_b_score} ${m.team_b_name}`}
      </Text>
      <Text style={{ fontSize: 12, color: colors.muted }}>{new Date(m.played_at).toLocaleDateString('pt-BR')}</Text>
    </View>
  );
}

function AwardRow({ cat, entry }: { cat: SeasonCategory; entry: NonNullable<SeasonAwardsData[SeasonCategory]> }) {
  const story = useArtFormat() === 'story';
  const winners = entry.winners;
  return (
    <View style={{ flexDirection: 'row', alignItems: 'center', gap: 12, justifyContent: story ? 'center' : 'flex-start' }}>
      <TrophyArt type={CATEGORY_TYPE[cat]} size={story ? 76 : 54} />
      <View style={{ flexShrink: 1, gap: 3 }}>
        <Text style={{ fontSize: 11, fontWeight: '800', letterSpacing: 0.8, color: colors.darkGold }}>{SEASON_AWARD_LABEL[CATEGORY_TYPE[cat]].toUpperCase()}</Text>
        {winners.map((w) => (
          <View key={w.membership_id} style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
            <Avatar path={w.avatar_path} name={w.name} size={story ? 34 : 28} />
            <View style={{ flexShrink: 1 }}>
              <Text style={{ fontSize: story ? 16 : 14, fontWeight: '800', color: colors.ink }} numberOfLines={1}>{w.name}</Text>
              <Text style={{ fontSize: 12, fontWeight: '800', color: blue }}>{statText(cat, w.value)}</Text>
            </View>
          </View>
        ))}
        {winners.length > 1 && <Text style={{ fontSize: 11, color: colors.muted }}>{sharedLabel(true)}</Text>}
      </View>
    </View>
  );
}

function Rule() {
  return <View style={{ height: 2, width: 40, backgroundColor: gold, alignSelf: 'center', borderRadius: 1 }} />;
}

export function RetroArt({
  id, retro, peladaName, crestPath, playerName, evolution, myMembershipId, myPhotoPath,
}: {
  id: ArtId;
  retro: OfficialRetro;
  peladaName: string;
  crestPath: string | null;
  playerName?: string;
  evolution?: number[];
  myMembershipId?: string | null;
  myPhotoPath?: string | null;
}) {
  const story = useArtFormat() === 'story';
  const sub = `Retrospectiva ${retro.season.name}`;
  const me = retro.me;
  const avg = retro.matches ? (retro.goals / retro.matches).toFixed(1).replace('.', ',') : '0';
  switch (id) {
    case 'P01':
      return (
        <View style={{ flex: story ? 1 : undefined, justifyContent: 'center', gap: story ? 18 : 10 }}>
          <Header title={peladaName} subtitle={sub} crestPath={crestPath} />
          <Rule />
          <Text style={{ textAlign: 'center', fontSize: story ? 30 : 24, fontWeight: '900', color: blue }}>{retro.season.name}</Text>
          <Text style={{ textAlign: 'center', color: colors.muted }}>{`${retro.matches} partidas · ${retro.goals} gols`}</Text>
        </View>
      );
    case 'P02':
      return (
        <>
          <Header title={peladaName} subtitle={sub} crestPath={crestPath} />
          <Grid>
            <Big value={String(retro.matches)} label="Partidas" />
            <Big value={String(retro.goals)} label="Gols" />
            <Big value={avg} label="Gols por jogo" />
            <Big value={String(retro.kings.length)} label="Meses com Rei" accent />
          </Grid>
        </>
      );
    case 'P03':
      return (
        <>
          <Header title={peladaName} subtitle={sub} crestPath={crestPath} />
          <Grid>
            <Podium title="Artilheiro" list={retro.scorers} unit="gols" />
            <Podium title="Garçom" list={retro.assisters} unit="assist." />
            <Podium title="Craque da Partida" list={retro.craques} unit="×" />
            <Podium title="Presença" list={retro.presence} unit="jogos" />
          </Grid>
        </>
      );
    case 'P04':
      return (
        <>
          <Header title={peladaName} subtitle={sub} crestPath={crestPath} />
          <Text style={{ textAlign: 'center', fontWeight: '800', color: blue, fontSize: story ? 20 : 16 }}>Mais vezes na Seleção da Rodada</Text>
          <Podium title="Destaques" list={retro.selection_leaders.slice(0, story ? 5 : 3)} unit="×" />
        </>
      );
    case 'P05':
      return (
        <>
          <Header title={peladaName} subtitle={sub} crestPath={crestPath} />
          <View style={{ gap: story ? 18 : 10 }}>
            <MatchLine label="Maior goleada" m={retro.biggest_win} />
            <MatchLine label="Mais gols" m={retro.most_goals} />
          </View>
        </>
      );
    case 'P07': {
      const cats = AWARD_CATEGORIES.filter((c) => retro.season_awards?.[c]?.winners.length);
      return (
        <>
          <Header title={peladaName} subtitle={sub} crestPath={crestPath} />
          <Text style={{ textAlign: 'center', fontWeight: '800', color: blue, fontSize: story ? 20 : 16 }}>Prêmios da temporada</Text>
          <View style={{ gap: story ? 18 : 10 }}>
            {cats.length === 0 && <Text style={{ textAlign: 'center', color: colors.muted }}>Sem prêmios de temporada publicados.</Text>}
            {cats.map((c) => (
              <AwardRow key={c} cat={c} entry={retro.season_awards![c]!} />
            ))}
          </View>
        </>
      );
    }
    case 'I06': {
      const mine = myAwardTitles(retro, myMembershipId);
      return (
        <>
          <Header title={playerName ?? ''} subtitle={`${peladaName} · ${retro.season.name}`} crestPath={crestPath} />
          <View style={{ alignItems: 'center', gap: 6 }}>
            <Avatar path={myPhotoPath} name={playerName ?? ''} size={story ? 72 : 56} />
            {mine.map((c) => {
              const w = retro.season_awards![c]!.winners.find((x) => x.membership_id === myMembershipId)!;
              return (
                <View key={c} style={{ alignItems: 'center', gap: 2 }}>
                  <TrophyArt type={CATEGORY_TYPE[c]} size={story ? 120 : 84} />
                  <Text style={{ fontSize: story ? 20 : 16, fontWeight: '900', color: colors.deepBlue }}>
                    {`${SEASON_AWARD_LABEL[CATEGORY_TYPE[c]]} ${seasonTag(retro.season.name)}`}
                  </Text>
                  <Text style={{ fontWeight: '800', color: colors.darkGold }}>{statText(c, w.value)}</Text>
                  {w.is_shared && <Text style={{ fontSize: 11, color: colors.muted }}>{sharedLabel(true)}</Text>}
                </View>
              );
            })}
          </View>
        </>
      );
    }
    case 'P06':
      return (
        <View style={{ flex: story ? 1 : undefined, justifyContent: 'center', gap: 12 }}>
          <Header title={peladaName} subtitle={sub} crestPath={crestPath} />
          <Rule />
          <Text style={{ textAlign: 'center', fontSize: story ? 24 : 20, fontWeight: '800', color: colors.deepBlue }}>Até a próxima temporada</Text>
        </View>
      );
    case 'I01':
      return (
        <>
          <Header title={playerName ?? ''} subtitle={`${peladaName} · ${retro.season.name}`} crestPath={crestPath} />
          <Grid>
            <Big value={String(me?.matches ?? 0)} label="Jogos" />
            <Big value={String(me?.wins ?? 0)} label="Vitórias" />
          </Grid>
        </>
      );
    case 'I02':
      return (
        <>
          <Header title={playerName ?? ''} subtitle={sub} crestPath={crestPath} />
          <Grid>
            <Big value={String(me?.goals ?? 0)} label="Gols" />
            <Big value={String(me?.assists ?? 0)} label="Assistências" />
            <Big value={`${me?.wins ?? 0}-${me?.draws ?? 0}-${me?.losses ?? 0}`} label="V-E-D" />
            <Big value={String(me?.matches ?? 0)} label="Jogos" />
          </Grid>
        </>
      );
    case 'I03': {
      const pts = evolution ?? [];
      const w = story ? 260 : 270;
      const h = story ? 160 : 110;
      const min = Math.min(...pts, 99);
      const max = Math.max(...pts, 0);
      const line = pts
        .map((v, i) => `${(i / Math.max(1, pts.length - 1)) * w},${h - ((v - min) / Math.max(1, max - min)) * h}`)
        .join(' ');
      return (
        <>
          <Header title={playerName ?? ''} subtitle={sub} crestPath={crestPath} />
          {pts.length > 1 ? (
            <View style={{ alignItems: 'center', gap: 6 }}>
              <Svg width={w} height={h}>
                <Polyline points={line} fill="none" stroke={blue} strokeWidth={3} strokeLinejoin="round" />
              </Svg>
              <Text style={{ fontWeight: '800', color: blue, fontSize: 18 }}>{`${pts[0]} → ${pts[pts.length - 1]}`}</Text>
            </View>
          ) : (
            <Text style={{ textAlign: 'center', color: colors.muted }}>Sem evolução registrada nesta temporada.</Text>
          )}
        </>
      );
    }
    case 'I04':
      return (
        <>
          <Header title={playerName ?? ''} subtitle={sub} crestPath={crestPath} />
          <Grid>
            <Big value={String(me?.craque ?? 0)} label="Craque da Partida" accent />
            <Big value={String(me?.kings ?? 0)} label="Rei do Mês" accent />
          </Grid>
        </>
      );
    case 'I05':
      return (
        <View style={{ gap: story ? 14 : 8 }}>
          <Header title={playerName ?? ''} subtitle={`${peladaName} · ${retro.season.name}`} crestPath={crestPath} />
          <Rule />
          <Text style={{ textAlign: 'center', fontSize: story ? 18 : 15, color: colors.ink }}>
            {`${me?.matches ?? 0} jogos, ${me?.goals ?? 0} gols e ${me?.assists ?? 0} assistências.`}
          </Text>
        </View>
      );
  }
}
