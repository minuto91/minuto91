import { useLocalSearchParams, useRouter } from 'expo-router';
import { useEffect, useState } from 'react';
import { Pressable, View } from 'react-native';

import { Crest, CrestDraft, CrestView, pickCrest, removeCrest, uploadCrest } from '../../../lib/crest';
import { confirm, notify } from '../../../lib/dialog';
import { friendly } from '../../../lib/errors';
import { centsToInput, formatBRL, parseBRL } from '../../../lib/money';
import { CrestSwatch } from '../../../lib/playercard';
import { CardsTracking } from '../../../lib/ratingadmin';
import { useAuth } from '../../../lib/session';
import { supabase } from '../../../lib/supabase';
import { Text } from '../../../lib/text';
import { colors, type } from '../../../lib/theme';
import { Toggle } from '../../../lib/toggle';
import { Body, Button, Card, Chips, ErrorText, Input, LoadingBlock, Screen, Stepper, Sub, Title } from '../../../lib/ui';

const DURATIONS = [
  { value: '120', label: '2 horas' },
  { value: '240', label: '4 horas' },
  { value: '360', label: '6 horas' },
] as const;
type Duration = (typeof DURATIONS)[number]['value'];

const MINIMUM = [
  { value: 'all', label: 'Todos' },
  { value: 'custom', label: 'Quantidade mínima' },
] as const;

// REV-031: índice compacto; cada seção abre só os próprios controles. As permissões continuam no servidor.
const SECTIONS = [
  { key: 'identidade', label: 'Identidade' },
  { key: 'times', label: 'Times' },
  { key: 'agenda', label: 'Agenda' },
  { key: 'votacao', label: 'Votação' },
  { key: 'cartoes', label: 'Registro de cartões' },
  { key: 'financeiro', label: 'Financeiro' },
  { key: 'plano', label: 'Plano' },
] as const;
type SectionKey = (typeof SECTIONS)[number]['key'];
const COLORS = ['azul', 'branco', 'preto', 'vermelho', 'amarelo', 'laranja', 'roxo', 'rosa'] as const;
const WEEKDAYS = ['Dom', 'Seg', 'Ter', 'Qua', 'Qui', 'Sex', 'Sáb'];
const validTime = (t: string) => t === '' || /^([01]\d|2[0-3]):[0-5]\d$/.test(t);

type Ident = { location: string; teamA: string; teamB: string; colorA: string | null; colorB: string | null; weekday: number | null; time: string };

// Configurações da pelada (só o admin). As de votação valem para as próximas votações.
export default function Configuracoes() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const router = useRouter();
  const [loaded, setLoaded] = useState(false);
  const [premium, setPremium] = useState(false);
  const [section, setSection] = useState<SectionKey | null>(null);
  const [duration, setDuration] = useState<Duration>('240');
  const [bolaMurcha, setBolaMurcha] = useState(true);
  const [minMode, setMinMode] = useState<'all' | 'custom'>('all');
  const [minimum, setMinimum] = useState(5);
  const [ident, setIdent] = useState<Ident>({ location: '', teamA: '', teamB: '', colorA: null, colorB: null, weekday: null, time: '' });
  const [monthly, setMonthly] = useState('');
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const [nome, setNome] = useState('');
  const [crest, setCrest] = useState<string | null>(null);
  const [crestBusy, setCrestBusy] = useState(false);
  const [draft, setDraft] = useState<CrestDraft | null>(null);
  // V6.1: a tela só serve ao admin (o servidor já recusa os outros); quem chega por link vê o aviso, não o formulário.
  const { session } = useAuth();
  const [isAdmin, setIsAdmin] = useState<boolean | null>(null);

  useEffect(() => {
    let alive = true;
    (async () => {
      const [{ data: st, error }, { data: ent }, { data: p }, { data: mine }] = await Promise.all([
        supabase
          .from('pelada_settings')
          .select('voting_duration_minutes, bola_murcha_enabled, minimum_numeric_ratings, default_monthly_cents')
          .eq('pelada_id', id)
          .maybeSingle(),
        supabase.rpc('get_pelada_entitlement', { p_pelada: id }),
        supabase
          .from('peladas')
          .select('name, crest_path, location, default_team_a_name, default_team_b_name, default_team_a_color, default_team_b_color, recurring_weekday, recurring_time')
          .eq('id', id)
          .maybeSingle(),
        supabase
          .from('pelada_memberships')
          .select('role')
          .eq('pelada_id', id)
          .eq('user_id', session?.user.id ?? '')
          .eq('status', 'active')
          .maybeSingle(),
      ]);
      if (!alive) return;
      if (error || !st) return setMsg(friendly(error?.message ?? 'PELADA_NOT_FOUND'));
      setDuration(String(st.voting_duration_minutes) as Duration);
      setBolaMurcha(!!st.bola_murcha_enabled);
      setMinMode(st.minimum_numeric_ratings === null ? 'all' : 'custom');
      if (st.minimum_numeric_ratings !== null) setMinimum(st.minimum_numeric_ratings);
      setMonthly(st.default_monthly_cents ? centsToInput(st.default_monthly_cents) : '');
      setIsAdmin(mine?.role === 'admin');
      setPremium(!!ent?.is_premium);
      setNome(p?.name ?? '');
      setCrest(p?.crest_path ?? null);
      setIdent({
        location: p?.location ?? '',
        teamA: p?.default_team_a_name ?? '',
        teamB: p?.default_team_b_name ?? '',
        colorA: p?.default_team_a_color ?? null,
        colorB: p?.default_team_b_color ?? null,
        weekday: p?.recurring_weekday ?? null,
        time: String(p?.recurring_time ?? '').slice(0, 5),
      });
      setLoaded(true);
    })();
    return () => {
      alive = false;
    };
  }, [id, session?.user.id]);

  async function trocarEscudo() {
    setCrestBusy(true);
    setMsg(null);
    try {
      const d = await pickCrest();
      if (d) setDraft(d);
    } catch (e) {
      setMsg((e as Error).message);
    } finally {
      setCrestBusy(false);
    }
  }

  async function salvarEscudo() {
    if (!draft) return;
    setCrestBusy(true);
    setMsg(null);
    try {
      setCrest(await uploadCrest(id, draft));
      setDraft(null);
    } catch (e) {
      setMsg((e as Error).message);
    } finally {
      setCrestBusy(false);
    }
  }

  function removerEscudo() {
    confirm('Remover o escudo?', 'A pelada volta a usar o escudo padrão com as iniciais.', 'Remover', async () => {
      setCrestBusy(true);
      setMsg(null);
      try {
        await removeCrest(id);
        setCrest(null);
      } catch (e) {
        setMsg((e as Error).message);
      } finally {
        setCrestBusy(false);
      }
    });
  }

  async function run(fn: string, args: Record<string, unknown>, done?: string) {
    if (busy) return;
    setBusy(true);
    setMsg(null);
    const { error } = await supabase.rpc(fn, args);
    setBusy(false);
    if (error) return setMsg(friendly(error.message)); // campos ficam como estavam
    if (done) notify('Salvo', done);
    setSection(null);
  }

  if (!loaded) {
    return (
      <Screen>
        <ErrorText>{msg}</ErrorText>
        {!msg && <LoadingBlock />}
      </Screen>
    );
  }

  if (!isAdmin) {
    return (
      <Screen>
        <Title>Configurações</Title>
        <Sub>Só o administrador altera as configurações.</Sub>
      </Screen>
    );
  }

  return (
    <Screen>
      <Title>{section ? SECTIONS.find((s) => s.key === section)!.label : 'Configurações'}</Title>

      {!section && (
        <View>
          {SECTIONS.map((s) => (
            <Pressable
              key={s.key}
              accessibilityRole="button"
              onPress={() => {
                setMsg(null);
                setSection(s.key);
              }}
              style={{ minHeight: 52, flexDirection: 'row', alignItems: 'center', borderBottomWidth: 1, borderBottomColor: colors.line }}>
              <Text style={[type.body, { flex: 1 }]}>{s.label}</Text>
              {s.key === 'plano' && <Text style={{ color: premium ? colors.darkGold : colors.muted, fontWeight: '700', marginRight: 8 }}>{premium ? 'Premium' : 'Basic'}</Text>}
              <Text style={{ color: colors.muted, fontSize: 18 }}>›</Text>
            </Pressable>
          ))}
        </View>
      )}

      {section === 'identidade' && (
        <>
          <Input autoCapitalize="sentences" placeholder="Local" value={ident.location} maxLength={120} onChangeText={(location) => setIdent({ ...ident, location })} />
          <Button title="Salvar local" kind="secondary" loading={busy} onPress={() => run('update_pelada_identity', { p_pelada: id, p: { location: ident.location } })} />
          <Card>
            <Body>Escudo</Body>
            <Sub>Prefira PNG com fundo transparente.</Sub>
            {draft ? (
              <View style={{ gap: 10 }}>
                <View style={{ flexDirection: 'row', justifyContent: 'center', gap: 8 }}>
                  {(['bronze', 'prata', 'ouro'] as const).map((t) => (
                    <CrestSwatch key={t} tier={t} crestUrl={draft.uri} peladaName={nome} width={92} />
                  ))}
                </View>
                <View style={{ flexDirection: 'row', alignItems: 'center', gap: 10, padding: 10, borderWidth: 1, borderColor: colors.line, borderRadius: 12 }}>
                  <CrestView url={draft.uri} name={nome} size={44} />
                  <Text style={{ flex: 1, fontSize: 18, fontWeight: '800', color: colors.ink }} numberOfLines={1}>
                    {nome}
                  </Text>
                </View>
                {draft.transparent === false && <Sub>Esta imagem não tem fundo transparente: o fundo aparece nos Cards e nas artes.</Sub>}
                <Button title="Salvar escudo" onPress={salvarEscudo} loading={crestBusy} />
                <Button title="Escolher outra imagem" kind="secondary" onPress={trocarEscudo} disabled={crestBusy} />
                <Button title="Cancelar" kind="ghost" onPress={() => setDraft(null)} disabled={crestBusy} />
              </View>
            ) : (
              <View style={{ flexDirection: 'row', alignItems: 'center', gap: 12 }}>
                <Crest path={crest} name={nome} size={64} />
                <View style={{ flex: 1, gap: 8 }}>
                  <Button title={crest ? 'Trocar escudo' : 'Enviar escudo'} kind="secondary" onPress={trocarEscudo} loading={crestBusy} />
                  {crest && <Button title="Remover escudo" kind="danger" onPress={removerEscudo} />}
                </View>
              </View>
            )}
          </Card>
        </>
      )}

      {section === 'times' && (
        <>
          {(['A', 'B'] as const).map((t) => {
            const color = t === 'A' ? ident.colorA : ident.colorB;
            const other = t === 'A' ? ident.colorB : ident.colorA;
            return (
              <View key={t} style={{ gap: 8 }}>
                <Input
                  autoCapitalize="sentences"
                  placeholder={`Time ${t}`}
                  value={t === 'A' ? ident.teamA : ident.teamB}
                  maxLength={40}
                  onChangeText={(v) => setIdent(t === 'A' ? { ...ident, teamA: v } : { ...ident, teamB: v })}
                />
                <Chips
                  options={COLORS.filter((c) => c !== other).map((c) => ({ value: c, label: c }))}
                  value={color}
                  onChange={(c) => setIdent(t === 'A' ? { ...ident, colorA: c } : { ...ident, colorB: c })}
                />
              </View>
            );
          })}
          <Button
            title="Salvar"
            loading={busy}
            onPress={() =>
              run('update_pelada_identity', {
                p_pelada: id,
                p: { team_a_name: ident.teamA, team_b_name: ident.teamB, team_a_color: ident.colorA, team_b_color: ident.colorB },
              })
            }
          />
        </>
      )}

      {section === 'agenda' && (
        <>
          <Chips
            options={WEEKDAYS.map((w, i) => ({ value: String(i), label: w }))}
            value={ident.weekday === null ? null : String(ident.weekday)}
            onChange={(v) => setIdent({ ...ident, weekday: Number(v) })}
          />
          <Input placeholder="20:00" keyboardType="numbers-and-punctuation" value={ident.time} maxLength={5} onChangeText={(time) => setIdent({ ...ident, time })} />
          {!validTime(ident.time) && <ErrorText>Use o formato 20:00.</ErrorText>}
          <Button
            title="Salvar"
            loading={busy}
            disabled={!validTime(ident.time)}
            onPress={() => run('update_pelada_identity', { p_pelada: id, p: { weekday: ident.weekday, time: ident.time || null } })}
          />
        </>
      )}

      {section === 'votacao' && (
        <>
          <Body>Prazo</Body>
          <Chips options={DURATIONS} value={duration} onChange={setDuration} />
          <Toggle label="Bola Murcha" premium={!premium} disabled={!premium} value={premium && bolaMurcha} onChange={setBolaMurcha} />
          <Body>Avaliações obrigatórias</Body>
          <Chips options={MINIMUM} value={minMode} onChange={setMinMode} />
          {minMode === 'custom' && <Stepper label="Mínimo" value={minimum} onChange={setMinimum} min={1} max={99} />}
          <Button
            title="Salvar"
            loading={busy}
            onPress={() =>
              run(
                'update_pelada_settings',
                {
                  p_pelada: id,
                  p_voting_duration_minutes: Number(duration),
                  p_bola_murcha_enabled: bolaMurcha,
                  p_minimum_numeric_ratings: minMode === 'all' ? null : minimum,
                },
                'Vale a partir da próxima votação.',
              )
            }
          />
        </>
      )}

      {section === 'cartoes' && <CardsTracking peladaId={id} isAdmin />}

      {section === 'financeiro' && (
        <>
          <Body>Mensalidade padrão</Body>
          <Input keyboardType="decimal-pad" placeholder="R$ 0,00" value={monthly} onChangeText={setMonthly} />
          {monthly && parseBRL(monthly) ? <Sub>{formatBRL(parseBRL(monthly)!)}</Sub> : null}
          <Button
            title="Salvar"
            loading={busy}
            onPress={() => run('set_default_monthly_amount', { p_pelada: id, p_amount_cents: monthly ? parseBRL(monthly) : null })}
          />
          <Button title="Abrir Financeiro" kind="ghost" onPress={() => router.push({ pathname: '/pelada/[id]/financeiro', params: { id } })} />
        </>
      )}

      {section === 'plano' && (
        <>
          <Body>{premium ? 'Pelada Premium' : 'Basic'}</Body>
          <Sub>Premium: R$ 29,90/mês por pelada.</Sub>
          <Button
            title={premium ? 'Ver plano' : 'Conhecer o Premium'}
            kind="secondary"
            onPress={() => router.push({ pathname: '/pelada/[id]/premium', params: { id } })}
          />
        </>
      )}

      <ErrorText>{msg}</ErrorText>
      {section && <Button title="Voltar às seções" kind="ghost" onPress={() => setSection(null)} />}
    </Screen>
  );
}
