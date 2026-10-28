import { useLocalSearchParams, useRouter } from 'expo-router';
import { useEffect, useMemo, useState } from 'react';
import { Pressable, useWindowDimensions, View } from 'react-native';
import { Text } from '../../../lib/text';

import { PlayerCard } from '../../../lib/arts';
import { cardPosition } from '../../../lib/playercard';
import { Avatar, prefetchAvatars } from '../../../lib/avatar';
import { Card as CardData, cardOverall, currentSeason, loadSeasons, Season, TIER } from '../../../lib/career';
import { Crest } from '../../../lib/crest';
import { friendly } from '../../../lib/errors';
import { supabase } from '../../../lib/supabase';
import { useSticky } from '../../../lib/sticky';
import { colors, POSITIONS, positionLabel, positionSector, SECTORS } from '../../../lib/theme';
import { Body, Button, Chips, EmptyState, ErrorText, Input, LoadingBlock, Screen, Sub, Title } from '../../../lib/ui';

type Row = { card: CardData; membershipId: string; name: string; userId: string | null };

const VIEWS = [
  { value: 'cartas', label: 'Cards' },
  { value: 'lista', label: 'Lista' },
] as const;
const SORTS = [
  { value: 'overall', label: 'Overall' },
  { value: 'nome', label: 'Nome' },
] as const;
const ALL = 'todas';
// Filtro por setor e, dentro dele, pelas posições oficiais (V4.3).
const SECTOR_FILTER = [{ value: ALL, label: 'Todas' }, ...SECTORS.map((s) => ({ value: s.value as string, label: s.label }))];
const PAGE = 20; // cartas desenhadas por vez (elencos de até 100)

// Elenco: só quem já tem carta oficial na temporada escolhida (calculada pelo servidor, provisória
// marcada como tal). Quem ainda não tem carta continua na pelada, joga e é administrado normalmente.
export default function Elenco() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const router = useRouter();
  const { width } = useWindowDimensions();
  const [pelada, setPelada] = useState<{ name: string; crest_path: string | null } | null>(null);
  const [seasons, setSeasons] = useState<Season[]>([]);
  const [seasonId, setSeasonId] = useState<string | null>(null);
  const [rows, setRows] = useState<Row[] | null>(null);
  const [photos, setPhotos] = useState<Record<string, string | null>>({});
  const [view, setView] = useSticky<'cartas' | 'lista'>(`elenco:${id}:view`, 'cartas');
  const [sort, setSort] = useSticky<'overall' | 'nome'>(`elenco:${id}:sort`, 'overall');
  const [sector, setSector] = useSticky<string>(`elenco:${id}:sector`, ALL);
  const [pos, setPos] = useSticky<string>(`elenco:${id}:pos`, ALL);
  const [query, setQuery] = useState('');
  const [limit, setLimit] = useState(PAGE);
  const [msg, setMsg] = useState<string | null>(null);

  useEffect(() => {
    let alive = true;
    (async () => {
      const [{ data: p }, ss] = await Promise.all([
        supabase.from('peladas').select('name, crest_path').eq('id', id).maybeSingle(),
        loadSeasons(id),
      ]);
      if (!alive) return;
      setPelada(p ?? null);
      setSeasons(ss);
      setSeasonId(currentSeason(ss)?.id ?? null);
      if (!ss.length) setRows([]);
    })().catch((e) => alive && setMsg(friendly((e as Error).message)));
    return () => {
      alive = false;
    };
  }, [id]);

  // Três consultas para o elenco inteiro (cartas, membros, fotos), nunca uma por jogador.
  useEffect(() => {
    if (!seasonId) return;
    let alive = true;
    (async () => {
      const [{ data: cs, error: e1 }, { data: ms, error: e2 }] = await Promise.all([
        supabase
          .from('player_cards')
          .select('id, membership_id, position, finishing, assisting, attendance, winning, peer_rating, overall, tier, is_provisional, matches_played, formula_version, atu, est, peq, res, dis, ovr_display')
          .eq('season_id', seasonId),
        supabase.from('pelada_memberships').select('id, user_id, player_name, position_code').eq('pelada_id', id).eq('status', 'active'),
      ]);
      if (e1 || e2) throw e1 ?? e2;
      const members = new Map((ms ?? []).map((m) => [m.id as string, m]));
      const list: Row[] = (cs ?? [])
        .filter((c) => members.has(c.membership_id))
        .map((c) => {
          const m = members.get(c.membership_id)!;
          return { card: { ...(c as CardData), position_code: m.position_code }, membershipId: m.id, name: m.player_name, userId: m.user_id };
        });
      const uids = list.map((r) => r.userId).filter((u): u is string => !!u);
      const { data: pr } = uids.length ? await supabase.from('profiles').select('id, avatar_path').in('id', uids) : { data: [] };
      // V4.4: as fotos são assinadas em lote (uma requisição a cada 100), não uma por jogador.
      await prefetchAvatars((pr ?? []).map((p) => p.avatar_path as string | null));
      if (!alive) return;
      setPhotos(Object.fromEntries((pr ?? []).map((p) => [p.id as string, p.avatar_path as string | null])));
      setRows(list);
      setLimit(PAGE);
    })().catch((e) => alive && setMsg(friendly((e as Error).message)));
    return () => {
      alive = false;
    };
  }, [id, seasonId]);

  const shown = useMemo(() => {
    const q = query.trim().toLocaleLowerCase('pt-BR');
    return (rows ?? [])
      .filter((r) => {
        const p = cardPosition(r.card);
        const okPos = (sector === ALL || positionSector(p) === sector) && (pos === ALL || p === pos);
        return okPos && (!q || r.name.toLocaleLowerCase('pt-BR').includes(q));
      })
      .sort((a, b) =>
        sort === 'overall' ? (cardOverall(b.card) ?? -1) - (cardOverall(a.card) ?? -1) || a.name.localeCompare(b.name, 'pt-BR') : a.name.localeCompare(b.name, 'pt-BR'),
      );
  }, [rows, query, sector, pos, sort]);

  const seasonName = seasons.find((s) => s.id === seasonId)?.name ?? '';
  const seasonStart = seasons.find((s) => s.id === seasonId)?.starts_on ?? null;
  const cardWidth = Math.min(200, Math.floor((Math.min(width, 520) - 40 - 12) / 2));
  const open = (r: Row) => router.push({ pathname: '/jogador/[id]', params: { id: r.membershipId } });
  const photoOf = (r: Row) => (r.userId ? photos[r.userId] : null);

  return (
    <Screen>
      <View style={{ flexDirection: 'row', alignItems: 'center', gap: 12 }}>
        {pelada && <Crest path={pelada.crest_path} name={pelada.name} size={44} />}
        <View style={{ flex: 1 }}>
          <Title>Elenco</Title>
          {pelada && <Sub>{pelada.name}</Sub>}
        </View>
      </View>
      {seasons.length > 1 && (
        <Chips options={seasons.map((s) => ({ value: s.id, label: s.name }))} value={seasonId} onChange={(v) => { setRows(null); setSeasonId(v); }} />
      )}
      <ErrorText>{msg}</ErrorText>

      {rows === null ? (
        !msg && <LoadingBlock />
      ) : rows.length === 0 ? (
        <View style={{ paddingVertical: 24, gap: 8, alignItems: 'center' }}>
          <EmptyState title="Sem Cards nesta temporada" />
          <Sub>Os Cards dos jogadores aparecerão aqui após as primeiras avaliações.</Sub>
        </View>
      ) : (
        <>
          <Input value={query} onChangeText={setQuery} placeholder="Buscar pelo nome" autoCapitalize="words" accessibilityLabel="Buscar jogador pelo nome" />
          <Chips options={SECTOR_FILTER} value={sector} onChange={(v) => { setSector(v); setPos(ALL); }} />
          {sector !== ALL && (
            <Chips
              options={[{ value: ALL, label: 'Todas do setor' }, ...POSITIONS.filter((p) => p.sector === sector).map((p) => ({ value: p.value as string, label: p.value }))]}
              value={pos}
              onChange={setPos}
            />
          )}
          <View style={{ flexDirection: 'row', justifyContent: 'space-between', flexWrap: 'wrap', gap: 8 }}>
            <Chips options={VIEWS} value={view} onChange={setView} />
            <Chips options={SORTS} value={sort} onChange={setSort} />
          </View>
          <Sub>
            {shown.length} de {rows.length} com Card. Quem ainda não tem Card continua na pelada normalmente.
          </Sub>

          {shown.length === 0 && <EmptyState title="Ninguém com esse filtro" />}

          {view === 'cartas' ? (
            <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 12, justifyContent: 'center' }}>
              {shown.slice(0, limit).map((r) => (
                <Pressable key={r.membershipId} accessibilityRole="button" accessibilityHint="Abre o Card do jogador nesta pelada" onPress={() => open(r)}>
                  <PlayerCard
                    card={r.card}
                    playerName={r.name}
                    photoPath={photoOf(r)}
                    peladaName={pelada?.name ?? ''}
                    crestPath={pelada?.crest_path}
                    seasonName={seasonName}
                    seasonStart={seasonStart}
                    width={cardWidth}
                  />
                </Pressable>
              ))}
            </View>
          ) : (
            shown.slice(0, limit).map((r) => {
              const t = TIER[r.card.tier];
              return (
                <Pressable
                  key={r.membershipId}
                  accessibilityRole="button"
                  onPress={() => open(r)}
                  style={{ flexDirection: 'row', alignItems: 'center', gap: 12, paddingVertical: 8, borderBottomWidth: 1, borderBottomColor: colors.line }}>
                  <Avatar path={photoOf(r)} name={r.name} size={40} />
                  <View style={{ flex: 1 }}>
                    <Body>{r.name}</Body>
                    <Sub>
                      {positionLabel(cardPosition(r.card))}
                      {r.card.is_provisional ? ' · provisório' : ''}
                    </Sub>
                  </View>
                  <View style={{ alignItems: 'center', minWidth: 52, paddingVertical: 4, borderRadius: 8, borderWidth: 2, borderColor: t.frame, backgroundColor: t.bg }}>
                    <Text style={{ fontSize: 18, fontWeight: '800', color: colors.deepBlue }}>{cardOverall(r.card) ?? '—'}</Text>
                    <Text style={{ fontSize: 9, fontWeight: '800', color: t.deep }}>{t.label.toUpperCase()}</Text>
                  </View>
                </Pressable>
              );
            })
          )}
          {shown.length > limit && <Button title={`Mostrar mais (${shown.length - limit})`} kind="secondary" onPress={() => setLimit(limit + PAGE)} />}
        </>
      )}
    </Screen>
  );
}
