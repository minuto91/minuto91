import { useLocalSearchParams, useRouter } from 'expo-router';
import { useEffect, useState } from 'react';

import { Crest, CrestDraft, CrestView, pickCrest, removeCrest, uploadCrest } from '../../../lib/crest';
import { confirm, notify } from '../../../lib/dialog';
import { friendly } from '../../../lib/errors';
import { CrestSwatch } from '../../../lib/playercard';
import { supabase } from '../../../lib/supabase';
import { Text, View } from 'react-native';

import { colors } from '../../../lib/theme';
import { Body, Button, Card, Chips, ErrorText, Screen, Stepper, Sub, Title } from '../../../lib/ui';

const DURATIONS = [
  { value: '120', label: '2 horas' },
  { value: '240', label: '4 horas' },
  { value: '360', label: '6 horas' },
] as const;
type Duration = (typeof DURATIONS)[number]['value'];

const ON_OFF = [
  { value: 'on', label: 'Ligada' },
  { value: 'off', label: 'Desligada' },
] as const;

const MINIMUM = [
  { value: 'all', label: 'Todos os colegas' },
  { value: 'custom', label: 'Um número mínimo' },
] as const;

// Configurações da pelada (só o admin). Valem para as próximas votações; a votação aberta não muda.
export default function Configuracoes() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const router = useRouter();
  const [loaded, setLoaded] = useState(false);
  const [premium, setPremium] = useState(false);
  const [duration, setDuration] = useState<Duration>('240');
  const [bolaMurcha, setBolaMurcha] = useState<'on' | 'off'>('on');
  const [minMode, setMinMode] = useState<'all' | 'custom'>('all');
  const [minimum, setMinimum] = useState(5);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const [nome, setNome] = useState('');
  const [crest, setCrest] = useState<string | null>(null);
  const [crestBusy, setCrestBusy] = useState(false);
  const [draft, setDraft] = useState<CrestDraft | null>(null);

  useEffect(() => {
    let alive = true;
    (async () => {
      const [{ data: st, error }, { data: ent }, { data: p }] = await Promise.all([
        supabase
          .from('pelada_settings')
          .select('voting_duration_minutes, bola_murcha_enabled, minimum_numeric_ratings')
          .eq('pelada_id', id)
          .maybeSingle(),
        supabase.rpc('get_pelada_entitlement', { p_pelada: id }),
        supabase.from('peladas').select('name, crest_path').eq('id', id).maybeSingle(),
      ]);
      if (!alive) return;
      if (error || !st) return setMsg(friendly(error?.message ?? 'PELADA_NOT_FOUND'));
      setDuration(String(st.voting_duration_minutes) as Duration);
      setBolaMurcha(st.bola_murcha_enabled ? 'on' : 'off');
      setMinMode(st.minimum_numeric_ratings === null ? 'all' : 'custom');
      if (st.minimum_numeric_ratings !== null) setMinimum(st.minimum_numeric_ratings);
      setPremium(!!ent?.is_premium);
      setNome(p?.name ?? '');
      setCrest(p?.crest_path ?? null);
      setLoaded(true);
    })();
    return () => {
      alive = false;
    };
  }, [id]);

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

  async function salvar() {
    setBusy(true);
    setMsg(null);
    const { error } = await supabase.rpc('update_pelada_settings', {
      p_pelada: id,
      p_voting_duration_minutes: Number(duration),
      p_bola_murcha_enabled: bolaMurcha === 'on',
      p_minimum_numeric_ratings: minMode === 'all' ? null : minimum,
    });
    setBusy(false);
    if (error) return setMsg(friendly(error.message));
    notify('Configurações salvas', 'Valem a partir da próxima votação.');
    router.back();
  }

  if (!loaded) {
    return (
      <Screen>
        <ErrorText>{msg}</ErrorText>
        {!msg && <Sub>Carregando...</Sub>}
      </Screen>
    );
  }

  return (
    <Screen>
      <Title>Configurações da pelada</Title>
      <Sub>As mudanças valem para as próximas votações. Uma votação já aberta continua como estava.</Sub>

      <Card>
        <Body>Escudo da pelada</Body>
        <Sub>Aparece no topo da pelada, nos Cards e nas artes. Prefira PNG com fundo transparente; o formato do escudo é mantido.</Sub>
        {draft ? (
          <View style={{ gap: 10 }}>
            <Body>Prévia: confira antes de salvar</Body>
            <View style={{ flexDirection: 'row', justifyContent: 'center', gap: 8 }}>
              {(['bronze', 'prata', 'ouro'] as const).map((t) => (
                <CrestSwatch key={t} tier={t} crestUrl={draft.uri} peladaName={nome} width={92} />
              ))}
            </View>
            {/* Cabeçalho da pelada (fundo branco, como na tela da pelada). */}
            <View style={{ flexDirection: 'row', alignItems: 'center', gap: 10, padding: 10, borderWidth: 1, borderColor: colors.line, borderRadius: 12 }}>
              <CrestView url={draft.uri} name={nome} size={44} />
              <Text style={{ flex: 1, fontSize: 18, fontWeight: '800', color: colors.deepBlue }} numberOfLines={1}>
                {nome}
              </Text>
            </View>
            {draft.transparent === false && (
              <Sub>
                Esta imagem não tem fundo transparente: o fundo dela aparece nos Cards e nas artes. Para um resultado melhor, use um
                PNG sem fundo.
              </Sub>
            )}
            <Button title="Salvar escudo" onPress={salvarEscudo} loading={crestBusy} />
            <Button title="Escolher outra imagem" kind="secondary" onPress={trocarEscudo} disabled={crestBusy} />
            <Button title="Cancelar" kind="secondary" onPress={() => setDraft(null)} disabled={crestBusy} />
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

      <Card>
        <Body>Prazo padrão da votação</Body>
        <Sub>Já vem marcado ao publicar a súmula (dá para trocar na hora).</Sub>
        <Chips options={DURATIONS} value={duration} onChange={setDuration} />
      </Card>

      <Card>
        <Body>Bola Murcha</Body>
        {premium ? (
          <Chips options={ON_OFF} value={bolaMurcha} onChange={setBolaMurcha} />
        ) : (
          <Sub>Recurso do Premium. Sem Premium, a votação não tem Bola Murcha.</Sub>
        )}
      </Card>

      <Card>
        <Body>Notas obrigatórias por eleitor</Body>
        <Sub>
          Quantos colegas cada um precisa avaliar com nota. Fora do mínimo, as notas ficam opcionais. “Não vi jogar”
          continua valendo para até metade dos colegas.
        </Sub>
        <Chips options={MINIMUM} value={minMode} onChange={setMinMode} />
        {minMode === 'custom' && <Stepper label="Mínimo" value={minimum} onChange={setMinimum} min={1} max={99} />}
      </Card>

      <ErrorText>{msg}</ErrorText>
      <Button title="Salvar" onPress={salvar} loading={busy} />
    </Screen>
  );
}
