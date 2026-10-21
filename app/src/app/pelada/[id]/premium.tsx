import { useLocalSearchParams } from 'expo-router';
import { useEffect, useState } from 'react';

import { friendly } from '../../../lib/errors';
import { supabase } from '../../../lib/supabase';
import { Body, Button, Card, ErrorText, Screen, Sub, Title } from '../../../lib/ui';

type Entitlement = {
  is_premium: boolean;
  source: 'beta' | 'trial' | 'subscription' | null;
  status: string;
  trial_ends_at: string | null;
  premium_until: string | null;
  is_admin: boolean;
  trial_available: boolean;
  has_open_subscription: boolean;
};

const FEATURES = [
  'Bola Murcha na votação',
  'Até 3 assistentes (grátis: 1)',
  'Nomes dos times personalizados',
  'Votação com horário fixo para encerrar',
  'Histórico completo, carreira e recordes de todas as temporadas',
  'Temporadas personalizadas',
];

const fmtDay = (iso: string) => new Date(iso).toLocaleDateString('pt-BR');

export default function PeladaPremium() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const [ent, setEnt] = useState<Entitlement | null>(null);
  const [reload, setReload] = useState(0);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);

  useEffect(() => {
    let alive = true;
    (async () => {
      const { data, error } = await supabase.rpc('get_pelada_entitlement', { p_pelada: id });
      if (!alive) return;
      if (error) setMsg(friendly(error.message));
      else setEnt(data as Entitlement);
    })();
    return () => {
      alive = false;
    };
  }, [id, reload]);

  async function comecarTeste() {
    setBusy(true);
    setMsg(null);
    const { error } = await supabase.rpc('start_premium_trial', { p_pelada: id });
    setBusy(false);
    if (error) return setMsg(friendly(error.message));
    setReload((n) => n + 1);
  }

  if (!ent) {
    return (
      <Screen>
        <ErrorText>{msg}</ErrorText>
        {!msg && <Sub>Carregando...</Sub>}
      </Screen>
    );
  }

  return (
    <Screen>
      <Title>Premium da pelada</Title>
      <Card>
        {ent.source === 'beta' && <Body>Premium liberado: estamos no beta, sem cobrança.</Body>}
        {ent.source === 'trial' && ent.trial_ends_at && <Body>Teste grátis até {fmtDay(ent.trial_ends_at)}.</Body>}
        {ent.source === 'subscription' && ent.premium_until && (
          <Body>
            Premium ativo até {fmtDay(ent.premium_until)}
            {ent.status === 'cancelled' ? ' (renovação cancelada)' : ''}.
          </Body>
        )}
        {!ent.is_premium && <Body>Esta pelada está no plano grátis.</Body>}
        <Sub>R$ 29,90 por mês, por pelada. Só o administrador contrata, e vale para todos os jogadores.</Sub>
      </Card>

      <Card>
        <Body>O que o Premium libera</Body>
        {FEATURES.map((f) => (
          <Sub key={f}>• {f}</Sub>
        ))}
        <Sub>Cartas, votação, Craque, rankings e álbum continuam grátis.</Sub>
      </Card>

      <ErrorText>{msg}</ErrorText>
      {ent.is_admin && ent.trial_available && !ent.is_premium && (
        <>
          <Button title="Começar teste grátis de 30 dias" onPress={comecarTeste} loading={busy} />
          <Sub>Sem cartão. Vale uma vez por pelada e uma vez por conta de administrador.</Sub>
        </>
      )}
      {ent.is_admin && !ent.is_premium && !ent.trial_available && (
        <Sub>A assinatura pela App Store e Google Play chega depois do beta.</Sub>
      )}
      {!ent.is_admin && !ent.is_premium && <Sub>Só o administrador da pelada pode ativar o Premium.</Sub>}
    </Screen>
  );
}
