import { useLocalSearchParams } from 'expo-router';
import { Platform } from 'react-native';
import { useEffect, useState } from 'react';
import type { PurchasesPackage } from 'react-native-purchases';

import { friendly } from '../../../lib/errors';
import { loadPremiumPackage, openManageSubscription, priceLabel, restorePurchases, storeAvailable, subscribePelada } from '../../../lib/purchases';
import { useAuth } from '../../../lib/session';
import { supabase } from '../../../lib/supabase';
import { Body, Button, Card, ErrorText, LoadingBlock, Screen, Sub, Title } from '../../../lib/ui';

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

// O que é de cada plano (V4.2, 12.3). Benefícios coletivos valem para todos da pelada; os administrativos
// são usados pelo admin (e assistentes, quando a função permite). Só o que existe no app.
const FREE = [
  'Partidas, times montados à mão, gols e assistências',
  'Votação, notas, Craque da Partida e Cards Bronze, Prata e Ouro',
  'Rankings, estatísticas, premiações e álbum',
  'Escalação visual depois do jogo e artes básicas',
  'Temporada atual e a anterior',
];
const PREMIUM_ALL = [
  'Duelo de Jogadores (comparação lado a lado, com arte)',
  'Histórico completo, carreira e recordes de todas as temporadas',
  'Arte especial com os rankings da temporada',
  'Bola Murcha na votação',
];
const PREMIUM_ADMIN = [
  'Sorteio automático de times equilibrado por posição (único ou por rodada)',
  'Escalação antes do jogo',
  'Nomes dos times personalizados',
  'Votação com horário fixo para encerrar',
  'Temporadas personalizadas',
  'Até 3 assistentes (grátis: 1)',
];

const fmtDay = (iso: string) => new Date(iso).toLocaleDateString('pt-BR');
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export default function PeladaPremium() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const [ent, setEnt] = useState<Entitlement | null>(null);
  const [reload, setReload] = useState(0);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const [info, setInfo] = useState<string | null>(null);
  const [pkg, setPkg] = useState<PurchasesPackage | null>(null);
  const [storeBusy, setStoreBusy] = useState<string | null>(null);
  const { session } = useAuth();
  const uid = session?.user.id;
  // Só o admin de uma pelada sem Premium (e fora do beta) vê a oferta da loja.
  const canBuy = !!ent && ent.is_admin && !ent.is_premium && ent.source !== 'beta';

  useEffect(() => {
    if (!canBuy || !storeAvailable || !uid) return;
    let alive = true;
    loadPremiumPackage(uid)
      .then((p) => alive && setPkg(p))
      .catch(() => alive && setMsg('Não foi possível carregar o preço na loja. Verifique a internet.'));
    return () => {
      alive = false;
    };
  }, [canBuy, uid]);

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

  // O banco só vira Premium quando o webhook da loja chega: confere por até ~30 s.
  async function aguardarConfirmacao() {
    for (let i = 0; i < 10; i++) {
      await sleep(3000);
      const { data } = await supabase.rpc('get_pelada_entitlement', { p_pelada: id });
      if ((data as Entitlement | null)?.is_premium) {
        setEnt(data as Entitlement);
        setInfo('Pelada Premium ativa. Obrigado!');
        return;
      }
    }
    setInfo('Pagamento enviado à loja. A Pelada Premium é liberada assim que a loja confirmar (pode levar alguns minutos).');
  }

  async function assinar() {
    if (!uid || !pkg) return;
    setStoreBusy('assinar');
    setMsg(null);
    setInfo(null);
    const r = await subscribePelada(uid, id, pkg);
    if (r.error) setMsg(r.error);
    else if (!r.cancelled) {
      setInfo('Confirmando o pagamento...');
      await aguardarConfirmacao();
    }
    setStoreBusy(null);
  }

  async function restaurar() {
    if (!uid) return;
    setStoreBusy('restaurar');
    setMsg(null);
    setInfo(null);
    const err = await restorePurchases(uid);
    if (err) setMsg(err);
    else {
      setInfo('Compras restauradas. Conferindo a assinatura...');
      await aguardarConfirmacao();
    }
    setStoreBusy(null);
  }

  async function gerenciar() {
    if (!uid) return;
    setMsg(null);
    const err = await openManageSubscription(uid);
    if (err) setMsg(err);
  }

  if (!ent) {
    return (
      <Screen>
        <ErrorText>{msg}</ErrorText>
        {!msg && <LoadingBlock />}
      </Screen>
    );
  }

  return (
    <Screen>
      <Title>Pelada Premium</Title>
      <Card>
        {ent.source === 'beta' && <Body>Pelada Premium liberada: estamos no beta, sem cobrança.</Body>}
        {ent.source === 'trial' && ent.trial_ends_at && <Body>Teste grátis até {fmtDay(ent.trial_ends_at)}.</Body>}
        {ent.source === 'subscription' && ent.premium_until && (
          <Body>
            Pelada Premium ativa até {fmtDay(ent.premium_until)}
            {ent.status === 'cancelled' ? ' (renovação cancelada)' : ''}.
          </Body>
        )}
        {!ent.is_premium && <Body>Esta pelada está no plano Básico (grátis).</Body>}
        <Sub>R$ 29,90/mês por pelada. Só o administrador contrata; vale para todos dela.</Sub>
      </Card>

      <Card>
        <Body>Básico (grátis)</Body>
        {FREE.map((f) => (
          <Sub key={f}>• {f}</Sub>
        ))}
      </Card>
      <Card>
        <Body>Pelada Premium: para todos da pelada</Body>
        {PREMIUM_ALL.map((f) => (
          <Sub key={f}>• {f}</Sub>
        ))}
        <Body>Pelada Premium: para quem organiza</Body>
        {PREMIUM_ADMIN.map((f) => (
          <Sub key={f}>• {f}</Sub>
        ))}
      </Card>

      <ErrorText>{msg}</ErrorText>
      {ent.is_admin && ent.trial_available && !ent.is_premium && (
        <>
          <Button title="Começar teste grátis de 30 dias" onPress={comecarTeste} loading={busy} />
          <Sub>Sem cartão. Vale uma vez por pelada e uma vez por conta de administrador.</Sub>
        </>
      )}
      {info && <Body>{info}</Body>}

      {canBuy &&
        (storeAvailable ? (
          <Card>
            <Body>Assinar a Pelada Premium</Body>
            <Sub>
              {pkg ? priceLabel(pkg) : 'Preço indisponível na loja agora'}, cobrado pela sua conta da{' '}
              {Platform.OS === 'ios' ? 'App Store' : 'Google Play'}. Renova todo mês; cancele quando quiser na loja. Sua
              conta da loja pode pagar uma pelada por vez.
            </Sub>
            <Button title="Assinar" onPress={assinar} loading={storeBusy === 'assinar'} disabled={!pkg || !!storeBusy} />
            <Button title="Restaurar compras" kind="secondary" onPress={restaurar} loading={storeBusy === 'restaurar'} disabled={!!storeBusy} />
          </Card>
        ) : (
          <Sub>A assinatura é feita no app instalado pela App Store ou Google Play.</Sub>
        ))}

      {ent.is_admin && ent.source === 'subscription' && storeAvailable && (
        <Card>
          <Button title="Gerenciar assinatura na loja" kind="secondary" onPress={gerenciar} />
          <Sub>Cancelar não apaga nada: a Pelada Premium vale até o fim do período pago e depois a pelada volta ao Básico.</Sub>
        </Card>
      )}
      {!ent.is_admin && !ent.is_premium && <Sub>Só o administrador da pelada pode assinar a Pelada Premium.</Sub>}
    </Screen>
  );
}
