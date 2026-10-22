import { useLocalSearchParams, useRouter } from 'expo-router';
import { useEffect, useState } from 'react';

import { Crest, pickAndUploadCrest, removeCrest } from '../../../lib/crest';
import { confirm, notify } from '../../../lib/dialog';
import { friendly } from '../../../lib/errors';
import { supabase } from '../../../lib/supabase';
import { View } from 'react-native';

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
      const path = await pickAndUploadCrest(id);
      if (path) setCrest(path);
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
        <Sub>Aparece no topo da pelada, nas cartas e nas artes. Imagem quadrada, PNG ou JPG.</Sub>
        <View style={{ flexDirection: 'row', alignItems: 'center', gap: 12 }}>
          <Crest path={crest} name={nome} size={64} />
          <View style={{ flex: 1, gap: 8 }}>
            <Button title={crest ? 'Trocar escudo' : 'Enviar escudo'} kind="secondary" onPress={trocarEscudo} loading={crestBusy} />
            {crest && <Button title="Remover escudo" kind="danger" onPress={removerEscudo} />}
          </View>
        </View>
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
