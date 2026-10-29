// V8.7: tela dos prêmios da temporada (Artilheiro, Maestro, Luva de Ouro) e, só para o administrador, a exceção da Luva.
// Parte visual sem rede (usada pela tela real e pela vitrine dev-v87). A autoridade é o servidor (get_season_awards, 068).
import { useState } from 'react';
import { View } from 'react-native';

import { Avatar } from './avatar';
import { Text } from './text';
import { colors, type } from './theme';
import { TrophyArt } from './trophies';
import { Body, Button, Card, Chips, EmptyState, ErrorText, Input, Screen, Section, Sub, Title } from './ui';
import {
  CATEGORY_TYPE, categoryStatusText, CategoryStatus, exceptionParamsError, SEASON_AWARD_LABEL, SeasonCategory, sharedLabel, statText,
} from './v87logic';

export type Winner = { membership_id: string; name: string; avatar_path: string | null; value: number | string | null; is_shared: boolean };
export type RankRow = { membership_id: string; name?: string | null; gk_matches?: number; ref?: number | string | null; avg_saves?: number | string | null; eligible?: boolean; official_position?: string | null; value?: number | string | null };
export type CategoryState = { status: CategoryStatus; version: number; basis: 'normal' | 'exception'; winners: Winner[]; ranking?: RankRow[]; criteria?: Record<string, unknown> };
export type AwardsState = {
  season_id: string;
  ready: boolean;
  is_admin: boolean;
  ref_note: string;
  categories: Partial<Record<SeasonCategory, CategoryState>>;
  golden_glove_exception?: {
    available: boolean;
    active: { min_percent: number; min_matches: number; reason: string; authorized_at: string } | null;
    floor_matches: number;
    candidates: RankRow[];
  };
};
export const CATEGORIES: SeasonCategory[] = ['top_scorer', 'maestro', 'golden_glove'];

export function AwardsView({ state, seasons, seasonId, onSeason, busy, msg, onGrant, onRevoke }: {
  state: AwardsState | null;
  seasons: { id: string; name: string }[];
  seasonId: string | null;
  onSeason: (id: string) => void;
  busy: boolean;
  msg: string | null;
  onGrant: (percent: number, minMatches: number, reason: string) => void;
  onRevoke: (reason: string) => void;
}) {
  return (
    <Screen>
      <Title>Prêmios da temporada</Title>
      {seasons.length > 1 && <Chips options={seasons.map((s) => ({ value: s.id, label: s.name }))} value={seasonId} onChange={(v) => onSeason(v)} />}
      <ErrorText>{msg}</ErrorText>
      {!state ? (
        <Sub>Carregando…</Sub>
      ) : (
        <>
          {!state.ready && Object.keys(state.categories).length === 0 && (
            <EmptyState title="Temporada em andamento ou em consolidação" hint="Os prêmios saem juntos depois do encerramento e da resolução das pendências." />
          )}
          {CATEGORIES.filter((c) => state.categories[c]).map((c) => (
            <CategoryCard key={c} cat={c} data={state.categories[c]!} isAdmin={state.is_admin} />
          ))}
          {state.categories.golden_glove && <Sub>{state.ref_note}</Sub>}
          {state.is_admin && state.golden_glove_exception?.available && (
            <ExceptionPanel ex={state.golden_glove_exception} busy={busy} onGrant={onGrant} onRevoke={onRevoke} />
          )}
        </>
      )}
    </Screen>
  );
}

function CategoryCard({ cat, data, isAdmin }: { cat: SeasonCategory; data: CategoryState; isAdmin: boolean }) {
  return (
    <Card>
      <View style={{ flexDirection: 'row', alignItems: 'center', gap: 12 }}>
        <TrophyArt type={CATEGORY_TYPE[cat]} size={56} dim={data.status !== 'published'} />
        <View style={{ flex: 1, gap: 2 }}>
          <Text style={type.cardTitle}>{SEASON_AWARD_LABEL[CATEGORY_TYPE[cat]]}</Text>
          <Sub>{data.status === 'published' ? (data.basis === 'exception' ? 'Concedido por exceção autorizada' : `Versão ${data.version}`) : categoryStatusText(cat, data.status, isAdmin)}</Sub>
        </View>
      </View>
      {data.winners.map((w) => (
        <View key={w.membership_id} style={{ flexDirection: 'row', alignItems: 'center', gap: 10, paddingTop: 8 }}>
          <Avatar path={w.avatar_path} name={w.name} size={36} />
          <Text style={{ flex: 1, fontWeight: '800', color: colors.ink }} numberOfLines={1}>{w.name}</Text>
          <Text style={{ fontWeight: '800', color: colors.blue }}>{statText(cat, w.value)}</Text>
        </View>
      ))}
      {data.winners.length > 1 && <Sub>{sharedLabel(true)}: cada um recebe o troféu inteiro.</Sub>}
    </Card>
  );
}

function ExceptionPanel({ ex, busy, onGrant, onRevoke }: {
  ex: NonNullable<AwardsState['golden_glove_exception']>;
  busy: boolean;
  onGrant: (percent: number, minMatches: number, reason: string) => void;
  onRevoke: (reason: string) => void;
}) {
  const [percent, setPercent] = useState('40');
  const [min, setMin] = useState('3');
  const [reason, setReason] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const grant = () => {
    const p = Number(percent);
    const m = Number(min);
    const bad = exceptionParamsError(p, m) ?? (reason.trim().length < 10 ? 'Explique o motivo (10 caracteres ou mais).' : null);
    setErr(bad);
    if (!bad) onGrant(p, m, reason.trim());
  };
  return (
    <>
      <Section>Exceção da Luva de Ouro</Section>
      <Card>
        <Body>Sem goleiro elegível pela regra normal (50% das partidas e mínimo de 5 como goleiro). Você pode reduzir o percentual e/ou o mínimo, com piso de {ex.floor_matches} atuações como goleiro. A posição oficial GOL, a REF e os desempates continuam valendo: você não escolhe o vencedor.</Body>
        {ex.candidates.length > 0 && (
          <Sub>{`Com ${ex.floor_matches} atuações ou mais: ${ex.candidates.map((c) => `${c.name ?? 'Goleiro'} (${c.gk_matches} jogos)`).join(', ')}.`}</Sub>
        )}
        {ex.active ? (
          <>
            <Sub>{`Exceção ativa: ${ex.active.min_percent}% e mínimo ${ex.active.min_matches}. Motivo: ${ex.active.reason}`}</Sub>
            <Input placeholder="motivo da revogação" value={reason} onChangeText={setReason} maxLength={500} />
            <Button title="Revogar exceção" kind="secondary" loading={busy} onPress={() => (reason.trim().length >= 10 ? onRevoke(reason.trim()) : setErr('Explique o motivo (10 caracteres ou mais).'))} />
          </>
        ) : null}
        <Input placeholder="percentual mínimo (0 a 50)" value={percent} onChangeText={setPercent} keyboardType="number-pad" />
        <Input placeholder="mínimo de partidas como goleiro (3 a 5)" value={min} onChangeText={setMin} keyboardType="number-pad" />
        <Input placeholder="motivo (obrigatório, fica no registro de auditoria)" value={reason} onChangeText={setReason} maxLength={500} multiline />
        <ErrorText>{err}</ErrorText>
        <Button title={ex.active ? 'Substituir exceção' : 'Autorizar exceção'} loading={busy} onPress={grant} />
      </Card>
    </>
  );
}
