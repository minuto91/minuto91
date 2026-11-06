// V10.0 — Seleção da Rodada (REV-097 a REV-121). Mostra os 11 eleitos da rodada em campo, a formação usada (acima do
// campo, sem edição), o estado da versão (Vigente / Substituída / Invalidada) e o histórico das seleções da MESMA
// pelada. Só leitura: nada aqui calcula, escolhe ou altera a Seleção (o algoritmo continua no servidor).
// Toque no jogador abre o Card no tamanho original sobre a tela escurecida; tocar fora fecha e volta à Seleção.
import { useLocalSearchParams } from 'expo-router';
import { useCallback, useEffect, useMemo, useState } from 'react';
import { Modal, Pressable, useWindowDimensions, View } from 'react-native';

import { friendly } from '../../../lib/errors';
import { fmtDate, loadMatch, loadMembers, Match, Member } from '../../../lib/match';
import { type Career, loadPlayer } from '../../../lib/profile';
import type { Card as CardData } from '../../../lib/career';
import { PlayerCard } from '../../../lib/playercard';
import { FieldPlayer, SelectionField, teamHex } from '../../../lib/selection';
import { arrange, type FormationName, isFormation, type Sector } from '../../../lib/selectionlayout';
import { supabase } from '../../../lib/supabase';
import { Text } from '../../../lib/text';
import { colors } from '../../../lib/theme';
import { Body, Button, Card, EmptyState, ErrorText, LoadingBlock, Screen, Sub } from '../../../lib/ui';
import { Icon } from '../../../lib/icons';

type Sel = { id: string; match_id: string; status: 'published' | 'superseded' | 'invalidated'; version: number; formation: string };
type SelPlayer = { selection_id: string; membership_id: string; slot_position: FieldPlayer['position']; rank_order: number; position_code: string | null };
type LineupPlayer = { team: 'A' | 'B'; membership_id: string | null; avatar_path: string | null };

const STATE_LABEL = { published: 'Vigente', superseded: 'Substituída', invalidated: 'Invalidada' } as const;

export default function SelecaoDaRodada() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const { width: screenW } = useWindowDimensions();
  const [match, setMatch] = useState<Match | null>(null);
  const [peladaName, setPeladaName] = useState('');
  const [members, setMembers] = useState<Member[]>([]);
  const [sels, setSels] = useState<Sel[]>([]);
  const [matches, setMatches] = useState<Record<string, Match>>({});
  const [players, setPlayers] = useState<SelPlayer[]>([]);
  const [viewId, setViewId] = useState<string | null>(null);
  const [lineup, setLineup] = useState<LineupPlayer[]>([]);
  const [colorsAB, setColorsAB] = useState<{ A: string | null; B: string | null }>({ A: null, B: null });
  const [showAll, setShowAll] = useState(false);
  const [open, setOpen] = useState<string | null>(null); // membership do Card ampliado
  const [card, setCard] = useState<{ status: 'loading' | 'ok' | 'none'; card?: Omit<CardData, 'id'>; name?: string; photo?: string | null; pelada?: string; crest?: string | null; season?: string; start?: string | null }>({ status: 'loading' });
  const [err, setErr] = useState<string | null>(null);
  const [loaded, setLoaded] = useState(false);
  const [reload, setReload] = useState(0);

  useEffect(() => {
    let alive = true;
    (async () => {
      void reload;
      try {
        const m = await loadMatch(id);
        if (!alive) return;
        if (!m) return setErr('Partida não encontrada.');
        const [ms, { data: ss, error: e1 }] = await Promise.all([
          loadMembers(m.pelada_id),
          supabase
            .from('round_selections')
            .select('id, match_id, status, version, formation')
            .eq('pelada_id', m.pelada_id)
            .in('status', ['published', 'superseded', 'invalidated']),
        ]);
        if (e1) throw e1;
        const list = (ss ?? []) as Sel[];
        const matchIds = [...new Set([m.id, ...list.map((s) => s.match_id)])];
        const [{ data: mm }, { data: pp }] = await Promise.all([
          supabase.from('matches').select('id, pelada_id, played_at, status, team_a_name, team_b_name, team_a_score:public_team_a_score, team_b_score:public_team_b_score, sheet_version').in('id', matchIds),
          list.length ? supabase.from('round_selection_players').select('selection_id, membership_id, slot_position, rank_order, position_code').in('selection_id', list.map((s) => s.id)) : Promise.resolve({ data: [] }),
        ]);
        if (!alive) return;
        const { data: pn } = await supabase.from('peladas').select('name').eq('id', m.pelada_id).maybeSingle();
        if (!alive) return;
        setPeladaName(pn?.name ?? '');
        setMatch(m);
        setMembers(ms);
        setSels(list);
        setMatches(Object.fromEntries(((mm ?? []) as Match[]).map((x) => [x.id, x])));
        setPlayers((pp ?? []) as SelPlayer[]);
        setViewId((cur) => cur ?? list.find((s) => s.match_id === m.id && s.status === 'published')?.id ?? null);
        setErr(null);
        setLoaded(true);
      } catch (e) {
        if (alive) setErr('Não foi possível carregar a Seleção da Rodada.' + (e instanceof Error && e.message ? '' : ''));
        void friendly;
      }
    })();
    return () => {
      alive = false;
    };
  }, [id, reload]);

  const viewing = sels.find((s) => s.id === viewId) ?? null;
  const viewMatchId = viewing?.match_id ?? null;

  // Fotos e times de quem está em campo na versão exibida, e as cores dos times daquela partida.
  useEffect(() => {
    if (!viewMatchId) return;
    let alive = true;
    (async () => {
      const [{ data: lu }, { data: cols }] = await Promise.all([
        supabase.rpc('get_match_lineup', { p_match: viewMatchId }),
        supabase.from('matches').select('team_a_color, team_b_color').eq('id', viewMatchId).maybeSingle(),
      ]);
      if (!alive) return;
      setLineup(((lu as { players?: LineupPlayer[] } | null)?.players ?? []) as LineupPlayer[]);
      setColorsAB({ A: teamHex(cols?.team_a_color) ?? null, B: teamHex(cols?.team_b_color) ?? null });
    })();
    return () => {
      alive = false;
    };
  }, [viewMatchId]);

  const nameOf = useCallback((mid: string) => members.find((m) => m.id === mid)?.player_name ?? 'Jogador', [members]);

  const formationOf = (selId: string): FormationName => {
    const f = sels.find((s) => s.id === selId)?.formation;
    return isFormation(f) ? f : '4-3-3';
  };

  function fieldFor(selId: string, rich: boolean): FieldPlayer[] {
    const mine = players.filter((p) => p.selection_id === selId).map((p) => ({ ...p, sector: p.slot_position as Sector, code: p.position_code, rank: p.rank_order }));
    return arrange(mine, formationOf(selId)).map(({ sector, row: x }, i): FieldPlayer => {
      {
        if (!x) return { key: `${sector}-${i}`, position: sector, name: null };
        const lp = rich ? lineup.find((l) => l.membership_id === x.membership_id) : undefined;
        // REV-119/120: só foto (ou iniciais) e nome; sem sigla, OVR, nota ou gols.
        return { key: x.membership_id, position: sector, name: nameOf(x.membership_id), posLabel: null, photoPath: lp?.avatar_path ?? null, teamColor: lp ? colorsAB[lp.team] : null };
      }
    });
  }

  // Card ampliado: busca o Card oficial daquele jogador na pelada (respeita a privacidade do servidor).
  useEffect(() => {
    if (!open || !match) return;
    let alive = true;
    (async () => {
      try {
        const mem = members.find((m) => m.id === open);
        if (!mem?.user_id) return alive && setCard({ status: 'none' });
        const { career, profile } = await loadPlayer(mem.user_id);
        const c = career as Career;
        if (!alive) return;
        if (!c.visible) return setCard({ status: 'none' });
        const p = c.peladas.find((x) => x.pelada_id === match.pelada_id);
        const s = p?.seasons.find((x) => x.card);
        if (!p || !s?.card) return setCard({ status: 'none' });
        setCard({ status: 'ok', card: s.card, name: mem.player_name, photo: (profile as { avatar_path?: string | null } | null)?.avatar_path ?? null, pelada: p.name, crest: p.crest_path, season: s.name, start: s.starts_on });
      } catch {
        if (alive) setCard({ status: 'none' });
      }
    })();
    return () => {
      alive = false;
    };
  }, [open, match, members]);

  // Histórico (REV-109/110/111): só desta pelada, do mais recente ao mais antigo (data oficial; empate: id).
  const history = useMemo(
    () =>
      [...sels].sort((a, b) => {
        const da = matches[a.match_id]?.played_at ?? '';
        const db = matches[b.match_id]?.played_at ?? '';
        return db.localeCompare(da) || b.match_id.localeCompare(a.match_id) || b.version - a.version;
      }),
    [sels, matches],
  );
  const shown = showAll ? history : history.slice(0, 3);

  if (!loaded) {
    return (
      <Screen>
        <ErrorText>{err}</ErrorText>
        {err ? <Button title="Tentar de novo" kind="secondary" onPress={() => { setErr(null); setReload((n) => n + 1); }} /> : <LoadingBlock />}
      </Screen>
    );
  }

  const thisMatchSels = sels.filter((s) => s.match_id === id);
  const noneOfficial = !viewing && thisMatchSels.length === 0;
  const unavailable = !viewing && thisMatchSels.some((s) => s.status === 'invalidated');
  const vm = viewing ? matches[viewing.match_id] : null;
  const fieldW = Math.min(340, screenW - 40);

  return (
    <Screen>
      {match && <Sub>{`${peladaName ? peladaName + ' · ' : ''}${fmtDate(match.played_at)} · ${match.team_a_name} x ${match.team_b_name}`}</Sub>}
      {err && <ErrorText>{err}</ErrorText>}

      {viewing && vm ? (
        <>
          <View style={{ flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: 8 }}>
            <Body>{`Rodada de ${fmtDate(vm.played_at)}`}</Body>
            <Text style={{ color: viewing.status === 'published' ? colors.blue : colors.muted, fontWeight: '700' }}>{STATE_LABEL[viewing.status]}</Text>
          </View>
          <Text style={{ textAlign: 'center', color: colors.muted, fontWeight: '700' }}>{viewing.formation}</Text>
          <View style={{ alignItems: 'center' }}>
            <SelectionField players={fieldFor(viewing.id, true)} width={fieldW} formation={viewing.formation} onPlayerPress={(key) => { setCard({ status: 'loading' }); setOpen(key); }} />
          </View>
          {viewing.match_id !== id || viewing.status !== 'published' ? (
            <Button
              title="Voltar à seleção atual"
              kind="secondary"
              onPress={() => setViewId(sels.find((s) => s.match_id === id && s.status === 'published')?.id ?? null)}
              disabled={!sels.some((s) => s.match_id === id && s.status === 'published')}
            />
          ) : null}
        </>
      ) : unavailable ? (
        <EmptyState title="Seleção da Rodada indisponível." />
      ) : noneOfficial ? (
        <EmptyState title="A Seleção da Rodada ainda não foi publicada." />
      ) : (
        <EmptyState title="Seleção da Rodada indisponível." />
      )}

      {history.length > 0 && (
        <View style={{ gap: 8, marginTop: 8 }}>
          <Body>Histórico de seleções</Body>
          {shown.map((s) => {
            const hm = matches[s.match_id];
            return (
              <Pressable key={s.id} accessibilityRole="button" accessibilityLabel={`Ver a Seleção de ${hm ? fmtDate(hm.played_at) : ''}, ${STATE_LABEL[s.status]}`} onPress={() => setViewId(s.id)}>
                <Card>
                  <View style={{ flexDirection: 'row', alignItems: 'center', gap: 12 }}>
                    <SelectionField players={fieldFor(s.id, false)} width={72} formation={s.formation} />
                    <View style={{ flex: 1, gap: 2 }}>
                      <Text style={{ color: colors.ink, fontWeight: '700' }}>{hm ? `Rodada de ${fmtDate(hm.played_at)}` : 'Rodada'}</Text>
                      {hm && <Sub>{`${hm.team_a_name} x ${hm.team_b_name}`}</Sub>}
                      <Text style={{ color: s.status === 'published' ? colors.blue : colors.muted, fontSize: 12, fontWeight: '700' }}>
                        {STATE_LABEL[s.status]}
                        {s.version > 1 || s.status !== 'published' ? ` · versão ${s.version}` : ''}
                      </Text>
                    </View>
                    <Icon name="chevron" size={20} color={colors.muted} />
                  </View>
                </Card>
              </Pressable>
            );
          })}
          {!showAll && history.length > 3 && <Button title="Ver todas as seleções" kind="secondary" onPress={() => setShowAll(true)} />}
        </View>
      )}

      {/* REV-100: Card no tamanho original sobre a tela escurecida; tocar fora fecha. */}
      <Modal visible={!!open} transparent animationType="fade" onRequestClose={() => setOpen(null)}>
        <Pressable accessibilityRole="button" accessibilityLabel="Fechar o Card" onPress={() => setOpen(null)} style={{ flex: 1, backgroundColor: 'rgba(15,23,42,0.72)', alignItems: 'center', justifyContent: 'center', padding: 20 }}>
          <Pressable onPress={() => {}} accessible={false}>
            {card.status === 'loading' && <LoadingBlock />}
            {card.status === 'none' && (
              <Card>
                <Sub>Card indisponível para este jogador.</Sub>
              </Card>
            )}
            {card.status === 'ok' && card.card && (
              <PlayerCard
                card={{ ...card.card, id: `sel-${open}` }}
                playerName={card.name ?? ''}
                photoPath={card.photo}
                peladaName={card.pelada ?? ''}
                crestPath={card.crest}
                seasonName={card.season ?? ''}
                seasonStart={card.start}
              />
            )}
          </Pressable>
        </Pressable>
      </Modal>
    </Screen>
  );
}
