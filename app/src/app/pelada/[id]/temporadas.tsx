import { useLocalSearchParams } from 'expo-router';
import { useEffect, useState } from 'react';

import { loadSeasons, Season } from '../../../lib/career';
import { todayIn } from '../../../lib/dates';
import { confirm, notify } from '../../../lib/dialog';
import { friendly } from '../../../lib/errors';
import { SeasonLifecycle } from '../../../lib/seasonlifecycle';
import { supabase } from '../../../lib/supabase';
import { Body, Button, Card, Chips, ErrorText, Input, LoadingBlock, Screen, Sub, Title } from '../../../lib/ui';

// A19: temporadas da pelada. Todos veem a lista (nome e período não são histórico); personalizar é do
// administrador com Pelada Premium (customize_season, migração 006). A regra de produto: com temporada em
// andamento o admin escolhe explicitamente "encerrar e começar outra" ou "manter a atual" (muda nome e fim).
const MODES = [
  { value: 'close_and_start', label: 'Encerrar e começar outra' },
  { value: 'keep_current', label: 'Manter a atual' },
] as const;
type Mode = (typeof MODES)[number]['value'];

const fmt = (d: string) => new Date(`${d}T12:00:00`).toLocaleDateString('pt-BR');
// DD/MM/AAAA -> AAAA-MM-DD (null se inválida).
function parseDay(v: string): string | null {
  const m = /^(\d{1,2})\/(\d{1,2})\/(\d{4})$/.exec(v.trim());
  if (!m) return null;
  const iso = `${m[3]}-${m[2].padStart(2, '0')}-${m[1].padStart(2, '0')}`;
  const d = new Date(`${iso}T12:00:00`);
  return Number.isNaN(d.getTime()) || d.toISOString().slice(0, 10) !== iso ? null : iso;
}

export default function Temporadas() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const [seasons, setSeasons] = useState<Season[] | null>(null);
  const [isAdmin, setIsAdmin] = useState(false);
  const [premium, setPremium] = useState(false);
  const [mode, setMode] = useState<Mode>('close_and_start');
  const [name, setName] = useState('');
  const [start, setStart] = useState('');
  const [end, setEnd] = useState('');
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const [reload, setReload] = useState(0);

  useEffect(() => {
    let alive = true;
    (async () => {
      try {
        const [ss, { data: ent, error }] = await Promise.all([loadSeasons(id), supabase.rpc('get_pelada_entitlement', { p_pelada: id })]);
        if (error) throw error;
        if (!alive) return;
        const e = ent as { is_premium: boolean; is_admin: boolean };
        setSeasons(ss);
        setIsAdmin(e.is_admin);
        setPremium(e.is_premium);
        setMsg(null);
      } catch (e) {
        if (alive) setMsg(friendly((e as Error).message));
      }
    })();
    return () => {
      alive = false;
    };
  }, [id, reload]);

  const today = todayIn();
  const current = seasons?.find((s) => s.starts_on <= today && s.ends_on >= today) ?? null;

  function salvar() {
    const s = mode === 'keep_current' ? today : parseDay(start);
    const e = parseDay(end);
    if (name.trim().length < 2) return setMsg('Dê um nome à temporada (2 a 60 caracteres).');
    if (!s || !e) return setMsg('Use datas no formato DD/MM/AAAA.');
    const effect =
      mode === 'keep_current'
        ? `A temporada atual passa a se chamar "${name.trim()}" e termina em ${fmt(e)}. Partidas, Cards e rankings continuam.`
        : `A temporada atual termina em ${fmt(new Date(new Date(`${s}T12:00:00`).getTime() - 86400000).toISOString().slice(0, 10))} e "${name.trim()}" começa em ${fmt(s)}. Nada é apagado; Cards e rankings recomeçam na nova temporada.`;
    confirm('Confirmar temporada?', effect, 'Confirmar', async () => {
      setBusy(true);
      setMsg(null);
      const { error } = await supabase.rpc('customize_season', {
        p_pelada: id,
        p_mode: mode,
        p_name: name.trim(),
        p_starts_on: mode === 'keep_current' ? null : s,
        p_ends_on: e,
        p_confirm: true,
      });
      setBusy(false);
      if (error) return setMsg(friendly(error.message));
      notify('Temporada salva');
      setName('');
      setStart('');
      setEnd('');
      setReload((n) => n + 1);
    });
  }

  return (
    <Screen>
      <Title>Temporadas</Title>
      <ErrorText>{msg}</ErrorText>
      {msg && !seasons && <Button title="Tentar de novo" kind="secondary" onPress={() => setReload((n) => n + 1)} />}
      {!seasons && !msg && <LoadingBlock />}
      {seasons?.map((s) => (
        <Card key={s.id}>
          <Body>
            {s.name}
            {s.id === current?.id ? ' · em andamento' : s.starts_on > today ? ' · planejada' : ' · encerrada'}
          </Body>
          <Sub>
            {fmt(s.starts_on)} a {fmt(s.ends_on)} · {s.kind === 'custom' ? 'personalizada' : 'ano civil'}
          </Sub>
          <SeasonLifecycle seasonId={s.id} isAdmin={isAdmin} onChanged={() => setReload((n) => n + 1)} />
        </Card>
      ))}

      {seasons && isAdmin && !premium && (
        <Sub>No Basic a temporada é o ano civil. Temporada personalizada é Premium.</Sub>
      )}
      {seasons && isAdmin && premium && (
        <Card>
          <Body>Personalizar temporada</Body>
          <Sub>Escolha o que acontece com a temporada em andamento. Nada é apagado.</Sub>
          <Chips options={MODES} value={mode} onChange={setMode} />
          <Input placeholder="nome (ex.: Temporada 2027/1)" value={name} onChangeText={setName} maxLength={60} autoCapitalize="sentences" />
          {mode === 'close_and_start' && (
            <Input placeholder="início DD/MM/AAAA (hoje ou depois)" value={start} onChangeText={setStart} keyboardType="numbers-and-punctuation" />
          )}
          <Input placeholder="fim DD/MM/AAAA" value={end} onChangeText={setEnd} keyboardType="numbers-and-punctuation" />
          <Button title="Salvar temporada" onPress={salvar} loading={busy} />
        </Card>
      )}
    </Screen>
  );
}
