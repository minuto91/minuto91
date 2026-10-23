// Perfil global e carreira (migrações 029 e 030). O perfil é da pessoa; a carta é o desempenho dela
// em uma pelada. Tudo vem pronto do servidor, que já aplica privacidade, bloqueios e o limite do
// plano grátis (temporada atual e anterior); aqui nada é recalculado, só somado para exibir.
import { useRouter } from 'expo-router';
import { Pressable, View } from 'react-native';
import { Text } from './text';

import { PlayerCard } from './arts';
import { AWARD_LABEL, Card as CardData, plural, TIER } from './career';
import { Crest } from './crest';
import { fmtRating } from './match';
import { supabase } from './supabase';
import { colors, positionLabel } from './theme';
import { Body, Card, Sub } from './ui';

export type Visibility = 'private' | 'peladas' | 'public';

export const VISIBILITY: readonly { value: Visibility; label: string; hint: string }[] = [
  { value: 'private', label: 'Privado', hint: 'Só você vê.' },
  { value: 'peladas', label: 'Minhas peladas', hint: 'Quem joga com você em alguma pelada vê.' },
  { value: 'public', label: 'Público', hint: 'Qualquer pessoa com conta no Minuto 91 vê.' },
];

export type MyProfile = {
  id: string;
  display_name: string;
  avatar_path: string | null;
  dominant_foot: string | null;
  profile_visibility: Visibility;
  career_visibility: Visibility;
};

export type ProfilePelada = {
  pelada_id: string;
  name: string;
  crest_path: string | null;
  membership_id: string;
  position: string;
  role: string;
  status: 'active' | 'left';
};

export type PlayerProfile =
  | { visible: false }
  | {
      visible: true;
      id: string;
      display_name: string;
      avatar_path: string | null;
      dominant_foot: string | null;
      is_me: boolean;
      career_visible: boolean;
      peladas: ProfilePelada[];
    };

export type Totals = {
  matches_played: number;
  wins: number;
  draws: number;
  losses: number;
  goals: number;
  assists: number;
  red_cards: number;
  craque_awards: number;
};

type CareerCard = Omit<CardData, 'id'>;

export type CareerSeason = Totals & {
  season_id: string;
  name: string;
  starts_on: string;
  ends_on: string;
  status: string;
  valid_ratings: number;
  avg_final_rating: number | null;
  card: CareerCard | null;
};

export type CareerPelada = {
  pelada_id: string;
  name: string;
  crest_path: string | null;
  membership_id: string;
  status: 'active' | 'left';
  position: string;
  full_history: boolean;
  hidden_seasons: number;
  totals: Totals;
  seasons: CareerSeason[];
};

export type Achievement = {
  type: string;
  pelada_id: string;
  pelada_name: string;
  season_name: string;
  period_month: string | null;
  played_at: string | null;
  is_shared: boolean;
};

export type Career =
  | { visible: false }
  | { visible: true; is_me: boolean; totals: Totals; peladas: CareerPelada[]; achievements: Achievement[] };

export async function loadMyProfile() {
  const { data, error } = await supabase.rpc('get_my_profile');
  if (error) throw error;
  return data as MyProfile | null;
}

export async function loadPlayer(userId: string) {
  const [p, c] = await Promise.all([
    supabase.rpc('get_player_profile', { p_user: userId }),
    supabase.rpc('get_player_career', { p_user: userId }),
  ]);
  if (p.error) throw p.error;
  if (c.error) throw c.error;
  return { profile: p.data as PlayerProfile, career: c.data as Career };
}

export const ACHIEVEMENT_LABEL: Record<string, string> = { ...AWARD_LABEL, round_selection: 'Seleção da Rodada' };

const fmtDay = (iso: string) => new Date(iso).toLocaleDateString('pt-BR');
const fmtMonthShort = (isoDate: string) =>
  new Date(`${isoDate}T12:00:00`).toLocaleDateString('pt-BR', { month: 'long', year: 'numeric' });

// ---------- Seções ----------

function Stat({ value, label }: { value: number | string; label: string }) {
  return (
    <View style={{ width: '25%', alignItems: 'center', paddingVertical: 6 }} accessibilityLabel={`${label}: ${value}`}>
      <Text style={{ fontSize: 22, fontWeight: '800', color: colors.deepBlue }}>{value}</Text>
      <Text style={{ fontSize: 12, color: colors.muted, textAlign: 'center' }}>{label}</Text>
    </View>
  );
}

export function TotalsGrid({ totals, selections }: { totals: Totals; selections?: number }) {
  return (
    <View style={{ flexDirection: 'row', flexWrap: 'wrap' }}>
      <Stat value={totals.matches_played} label="Jogos" />
      <Stat value={totals.wins} label="Vitórias" />
      <Stat value={totals.draws} label="Empates" />
      <Stat value={totals.losses} label="Derrotas" />
      <Stat value={totals.goals} label="Gols" />
      <Stat value={totals.assists} label="Assist." />
      <Stat value={totals.craque_awards} label="Craque" />
      {selections !== undefined && <Stat value={selections} label="Seleção" />}
    </View>
  );
}

const anyHidden = (c: Extract<Career, { visible: true }>) => c.peladas.some((p) => p.hidden_seasons > 0);

/** Total geral + nota do que ficou de fora pelo plano. */
export function CareerSummary({ career }: { career: Extract<Career, { visible: true }> }) {
  const selections = career.achievements.filter((a) => a.type === 'round_selection').length;
  const partial = anyHidden(career);
  // Total parcial nunca aparece como se fosse a carreira inteira.
  return (
    <Card>
      <Body>{partial ? 'Total nas temporadas disponíveis' : 'Total na carreira'}</Body>
      <TotalsGrid totals={career.totals} selections={selections} />
      {partial && (
        <Sub>
          Este total não inclui temporadas antigas de peladas sem Premium (elas mostram só a temporada atual e a anterior). O
          histórico completo é da Pelada Premium (de cada pelada).
        </Sub>
      )}
    </Card>
  );
}

/** Carreira por pelada e por temporada. */
export function CareerByPelada({ career }: { career: Extract<Career, { visible: true }> }) {
  if (career.peladas.length === 0) return <Sub>Nenhuma pelada ainda.</Sub>;
  return (
    <>
      {career.peladas.map((p) => (
        <Card key={p.membership_id}>
          <View style={{ flexDirection: 'row', alignItems: 'center', gap: 10 }}>
            <Crest path={p.crest_path} name={p.name} size={32} />
            <View style={{ flex: 1 }}>
              <Body>{p.name}</Body>
              <Sub>
                {positionLabel(p.position)}
                {p.status === 'left' ? ' · saiu da pelada' : ''}
              </Sub>
            </View>
          </View>
          {p.hidden_seasons > 0 && <Sub>Total das temporadas disponíveis</Sub>}
          <TotalsGrid totals={p.totals} />
          {p.seasons.length === 0 && <Sub>Sem partidas finalizadas nas temporadas disponíveis.</Sub>}
          {p.seasons.map((s) => (
            <View key={s.season_id} style={{ borderTopWidth: 1, borderTopColor: colors.line, paddingTop: 8, gap: 2 }}>
              <Text style={{ fontWeight: '700', color: colors.ink }}>
                {s.name}
                {s.card ? ` · overall ${Math.round(Number(s.card.overall))} ${TIER[s.card.tier].label}` : ''}
                {s.card?.is_provisional ? ' (provisório)' : ''}
              </Text>
              <Sub>
                {plural(s.matches_played, 'jogo', 'jogos')} · {s.wins}V {s.draws}E {s.losses}D · {plural(s.goals, 'gol', 'gols')} ·{' '}
                {plural(s.assists, 'assist.', 'assist.')}
              </Sub>
              <Sub>
                Média de nota: {s.avg_final_rating !== null ? fmtRating(Number(s.avg_final_rating)) : '–'}
                {s.craque_awards ? ` · ${plural(s.craque_awards, 'Craque', 'Craques')}` : ''}
              </Sub>
            </View>
          ))}
          {p.hidden_seasons > 0 && (
            <Sub>
              + {plural(p.hidden_seasons, 'temporada anterior', 'temporadas anteriores')} no histórico completo (Pelada Premium).
            </Sub>
          )}
        </Card>
      ))}
    </>
  );
}

export function AchievementsList({ items }: { items: Achievement[] }) {
  if (items.length === 0) {
    return <Sub>Nenhuma conquista ainda. Craque da Partida, prêmios do mês e Seleção da Rodada aparecem aqui.</Sub>;
  }
  return (
    <Card>
      {items.map((a, i) => (
        <View key={i} style={{ paddingVertical: 6, borderTopWidth: i ? 1 : 0, borderTopColor: colors.line }}>
          <Text style={{ fontWeight: '700', color: colors.ink }}>
            {ACHIEVEMENT_LABEL[a.type] ?? a.type}
            {a.is_shared ? ' (dividido)' : ''}
          </Text>
          <Sub>
            {a.pelada_name} · {a.season_name}
            {a.played_at ? ` · ${fmtDay(a.played_at)}` : a.period_month ? ` · ${fmtMonthShort(a.period_month)}` : ''}
          </Sub>
        </View>
      ))}
    </Card>
  );
}

/** Carta mais recente de cada pelada ativa (temporada mais nova disponível). */
export function CardsList({
  career,
  playerName,
  photoPath,
}: {
  career: Extract<Career, { visible: true }>;
  playerName: string;
  photoPath: string | null | undefined;
}) {
  const cards = career.peladas
    .filter((p) => p.status === 'active')
    .map((p) => ({ p, s: p.seasons.find((s) => s.card) }))
    .filter((x): x is { p: CareerPelada; s: CareerSeason & { card: CareerCard } } => !!x.s?.card);
  if (cards.length === 0) return <Sub>Os Cards aparecem depois da primeira partida finalizada em cada pelada.</Sub>;
  return (
    <View style={{ gap: 16, alignItems: 'center' }}>
      {cards.map(({ p, s }) => (
        <PlayerCard
          key={p.membership_id}
          card={{ ...s.card, id: `${p.membership_id}-${s.season_id}` }}
          playerName={playerName}
          photoPath={photoPath}
          peladaName={p.name}
          crestPath={p.crest_path}
          seasonName={s.name}
          seasonStart={s.starts_on}
        />
      ))}
    </View>
  );
}

export function PeladasList({ peladas, isMe }: { peladas: ProfilePelada[]; isMe: boolean }) {
  const router = useRouter();
  if (peladas.length === 0) return <Sub>Nenhuma pelada.</Sub>;
  const roleName = (r: string) => (r === 'admin' ? 'Administrador' : r === 'assistant' ? 'Assistente' : 'Jogador');
  return (
    <>
      {peladas.map((p) => {
        const content = (
          <View style={{ flexDirection: 'row', alignItems: 'center', gap: 12 }}>
            <Crest path={p.crest_path} name={p.name} size={40} />
            <View style={{ flex: 1 }}>
              <Body>{p.name}</Body>
              <Sub>
                {p.status === 'left' ? 'Saiu da pelada · histórico guardado' : `${roleName(p.role)} · ${positionLabel(p.position)}`}
              </Sub>
            </View>
            {isMe && p.status === 'active' && <Text style={{ color: colors.muted, fontSize: 18 }}>›</Text>}
          </View>
        );
        return isMe && p.status === 'active' ? (
          <Pressable
            key={p.membership_id}
            accessibilityRole="button"
            onPress={() => router.push({ pathname: '/pelada/[id]', params: { id: p.pelada_id } })}>
            <Card>{content}</Card>
          </Pressable>
        ) : (
          <Card key={p.membership_id}>{content}</Card>
        );
      })}
    </>
  );
}
