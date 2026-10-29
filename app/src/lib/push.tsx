// Notificações push (V4.1). O servidor enfileira e envia (022 + 035 + Edge Function push-sender);
// aqui o app só: pede permissão quando a pessoa toca em "Ativar", registra o token do Expo deste
// aparelho (register_push_device), troca o token quando o sistema troca, remove ao sair da conta e
// abre a tela certa ao tocar no aviso.
// Só funciona no app instalado (development build ou loja) com projectId do EAS. Não funciona na web,
// no simulador nem no Expo Go: nesses casos pushSupported é false e nada é chamado.
import AsyncStorage from '@react-native-async-storage/async-storage';
import Constants from 'expo-constants';
import * as Device from 'expo-device';
import * as Notifications from 'expo-notifications';
import { AndroidImportance } from 'expo-notifications';
import { useRouter } from 'expo-router';
import { useEffect, useRef, useState } from 'react';
import { Platform, Switch, View } from 'react-native';
import { Text } from './text';

import { friendly } from './errors';
import { planPushOpen } from './navguard';
import { supabase } from './supabase';
import { colors, HOME } from './theme';
import { Button, Sub } from './ui';

const TOKEN_KEY = 'push_token';
const projectId: string | undefined = Constants.expoConfig?.extra?.eas?.projectId ?? Constants.easConfig?.projectId;

/** Aparelho real, app instalado (não Expo Go) e projeto EAS configurado. */
export const pushSupported =
  Platform.OS !== 'web' && Device.isDevice && Constants.executionEnvironment !== 'storeClient' && !!projectId;

export type PushStatus = 'unsupported' | 'granted' | 'denied' | 'undetermined';

if (pushSupported) {
  // Com o app aberto, o aviso aparece como banner (sem badge).
  Notifications.setNotificationHandler({
    handleNotification: async () => ({ shouldShowBanner: true, shouldShowList: true, shouldPlaySound: true, shouldSetBadge: false }),
  });
}

export async function pushStatus(): Promise<PushStatus> {
  if (!pushSupported) return 'unsupported';
  const p = await Notifications.getPermissionsAsync();
  return p.granted ? 'granted' : p.canAskAgain ? 'undetermined' : 'denied';
}

async function register() {
  if (Platform.OS === 'android') {
    await Notifications.setNotificationChannelAsync('default', {
      name: 'Avisos da pelada',
      importance: AndroidImportance.HIGH,
    });
  }
  const { data: token } = await Notifications.getExpoPushTokenAsync({ projectId });
  const { error } = await supabase.rpc('register_push_device', { p_token: token, p_platform: Platform.OS });
  if (error) throw error;
  await AsyncStorage.setItem(TOKEN_KEY, token);
}

/** Toque em "Ativar": pede a permissão do sistema e registra o aparelho. */
export async function enablePush(): Promise<PushStatus> {
  if (!pushSupported) return 'unsupported';
  const p = await Notifications.requestPermissionsAsync();
  if (!p.granted) return p.canAskAgain ? 'undetermined' : 'denied';
  await register();
  return 'granted';
}

/** Ao entrar na conta ou abrir o app: renova o registro sem perguntar nada (só se já houver permissão). */
export async function refreshPushRegistration() {
  if ((await pushStatus()) !== 'granted') return;
  await register();
}

/** Antes de sair da conta: este aparelho deixa de receber os avisos desta conta. */
export async function unregisterPush() {
  const token = await AsyncStorage.getItem(TOKEN_KEY);
  if (!token) return;
  await supabase.rpc('unregister_push_device', { p_token: token });
  await AsyncStorage.removeItem(TOKEN_KEY);
}

/**
 * Montado só quando pushSupported: abre a tela do aviso tocado e acompanha a troca de token. E15-17/20: o caminho
 * vem do servidor mas só rotas do app com ID válido abrem (navguard); com o app encerrado a Central entra primeiro,
 * para o "voltar" terminar nela; com o app aberto o destino empilha. O destino revalida login e acesso sozinho.
 */
export function PushHandler() {
  const router = useRouter();
  const response = Notifications.useLastNotificationResponse();
  const handledFirst = useRef(false);

  useEffect(() => {
    if (!response || response.actionIdentifier !== Notifications.DEFAULT_ACTION_IDENTIFIER) return;
    // A primeira resposta lida logo ao montar é a de um toque que abriu o app (partida a frio).
    const cold = !handledFirst.current;
    handledFirst.current = true;
    const path = response.notification.request.content.data?.path;
    Notifications.clearLastNotificationResponse();
    for (const step of planPushOpen(path, cold)) {
      if (step === '/') router.replace(HOME);
      else router.push(step as never);
    }
  }, [response, router]);

  useEffect(() => {
    // O sistema pode trocar o token do aparelho; registramos o novo token do Expo.
    const sub = Notifications.addPushTokenListener(() => {
      refreshPushRegistration().catch(() => {});
    });
    return () => sub.remove();
  }, []);

  return null;
}

type Category = 'match_voting' | 'voting_reminder' | 'results' | 'awards' | 'pelada';
type Prefs = { essential: boolean; engagement: boolean; categories: Record<Category, boolean> };

// V4.4: uma chave por categoria (045). As duas chaves gerais da V4.1 continuam no servidor para apps antigos: aqui a
// categoria aparece ligada só se a geral dela também estiver; ligar uma categoria religa a geral correspondente.
// Nenhum aviso traz valores financeiros; cobrança automática não existe.
// REV-040: três níveis — urgentes, administrativas e informativas. Avisos repetidos já são agrupados no servidor
// (um por operação); cada aviso abre a tela da partida/pelada correspondente.
type Tier = 'urgent' | 'admin' | 'info';
const TIERS: { key: Tier; label: string }[] = [
  { key: 'urgent', label: 'Urgentes' },
  { key: 'admin', label: 'Administrativas' },
  { key: 'info', label: 'Informativas' },
];
const CATEGORIES: { key: Category; tier: Tier; group: 'essential' | 'engagement'; label: string; hint: string }[] = [
  { key: 'match_voting', tier: 'urgent', group: 'essential', label: 'Votação aberta', hint: 'Súmula publicada, corrigida ou votação reiniciada.' },
  { key: 'voting_reminder', tier: 'urgent', group: 'essential', label: 'Lembrete de votação', hint: 'Perto do prazo, se você ainda não votou.' },
  { key: 'pelada', tier: 'admin', group: 'essential', label: 'Avisos da pelada', hint: 'Administração, funções e assinatura.' },
  { key: 'results', tier: 'info', group: 'essential', label: 'Resultados', hint: 'Resultado publicado ou partida anulada.' },
  { key: 'awards', tier: 'info', group: 'engagement', label: 'Conquistas', hint: 'Prêmios, figurinhas e retrospectiva.' },
];
const ALL_ON: Record<Category, boolean> = { match_voting: true, voting_reminder: true, results: true, awards: true, pelada: true };

/** Minha conta > Notificações: estado deste aparelho e uma preferência por categoria (vale para todos os aparelhos). */
export function NotificationSettings() {
  const [status, setStatus] = useState<PushStatus | null>(null);
  const [prefs, setPrefs] = useState<Prefs | null>(null);
  const [legacy, setLegacy] = useState(false); // servidor sem a migração 045
  const [msg, setMsg] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    let alive = true;
    (async () => {
      const [s, r] = await Promise.all([pushStatus(), supabase.rpc('get_notification_preferences')]);
      if (!alive) return;
      setStatus(s);
      if (!r.error) return setPrefs(r.data as Prefs);
      const { data } = await supabase.from('notification_preferences').select('essential, engagement').maybeSingle();
      if (!alive) return;
      setLegacy(true);
      setPrefs({ ...((data as Omit<Prefs, 'categories'> | null) ?? { essential: true, engagement: true }), categories: ALL_ON });
    })();
    return () => {
      alive = false;
    };
  }, []);

  async function toggle(c: (typeof CATEGORIES)[number], on: boolean) {
    if (!prefs) return;
    const before = prefs;
    const next: Prefs = { ...prefs, categories: { ...prefs.categories, [c.key]: on } };
    if (on) next[c.group] = true;
    setPrefs(next);
    setMsg(null);
    // Religar a geral desta categoria (desligada por um app antigo), sem mudar a outra.
    if (on && !before[c.group]) {
      const { error } = await supabase.rpc('set_notification_preferences', { p_essential: next.essential, p_engagement: next.engagement });
      if (error) {
        setPrefs(before);
        return setMsg(friendly(error.message));
      }
    }
    const { data, error } = legacy
      ? await supabase.rpc('set_notification_preferences', {
          p_essential: c.group === 'essential' ? on : next.essential,
          p_engagement: c.group === 'engagement' ? on : next.engagement,
        })
      : await supabase.rpc('set_notification_category', { p_category: c.key, p_enabled: on });
    if (error) {
      setPrefs(before);
      return setMsg(friendly(error.message));
    }
    if (!legacy && data) setPrefs(data as Prefs);
  }

  async function ativar() {
    setBusy(true);
    setMsg(null);
    try {
      setStatus(await enablePush());
    } catch (e) {
      setMsg(friendly((e as Error).message));
    }
    setBusy(false);
  }

  return (
    <View style={{ gap: 10 }}>
      {status === 'unsupported' && (
        <Sub>Avisos só no app instalado.</Sub>
      )}
      {status === 'denied' && <Sub>Os avisos estão bloqueados nos ajustes do celular. Libere em Ajustes &gt; Minuto 91 &gt; Notificações.</Sub>}
      {status === 'undetermined' && <Button title="Ativar avisos neste celular" onPress={ativar} loading={busy} />}
      {status === 'granted' && <Text style={{ color: colors.deepBlue, fontWeight: '600' }}>Avisos ativados neste celular.</Text>}
      {prefs &&
        TIERS.map((t) => (
          <View key={t.key} style={{ gap: 8 }}>
            <Text style={{ color: colors.muted, fontSize: 12, fontWeight: '700', letterSpacing: 0.5 }}>{t.label.toUpperCase()}</Text>
            {CATEGORIES.filter((c) => c.tier === t.key).map((c) => (
              <Row
                key={c.key}
                label={c.label}
                hint={c.hint}
                value={prefs[c.group] && prefs.categories[c.key] !== false}
                onChange={(v) => toggle(c, v)}
              />
            ))}
          </View>
        ))}
      {prefs && <Sub>Avisos de segurança da conta sempre chegam.</Sub>}
      {msg && <Text style={{ color: colors.danger }}>{msg}</Text>}
    </View>
  );
}

function Row({ label, hint, value, onChange }: { label: string; hint: string; value: boolean; onChange: (v: boolean) => void }) {
  return (
    <View style={{ flexDirection: 'row', alignItems: 'center', gap: 12 }}>
      <View style={{ flex: 1, gap: 2 }}>
        <Text style={{ color: colors.ink, fontWeight: '600' }}>{label}</Text>
        <Text style={{ color: colors.muted, fontSize: 13 }}>{hint}</Text>
      </View>
      <Switch
        value={value}
        onValueChange={onChange}
        trackColor={{ true: colors.blue, false: colors.line }}
        thumbColor={colors.white}
        {...({ activeThumbColor: colors.white } as object)}
        ios_backgroundColor={colors.line}
        accessibilityLabel={label}
      />
    </View>
  );
}

const PROMPT_KEY = 'push_prompt_dismissed';

/** Início: convite discreto para ativar os avisos (uma vez; "Agora não" não pergunta de novo). */
export function PushPrompt() {
  const [show, setShow] = useState(false);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    let alive = true;
    (async () => {
      const [s, dismissed] = await Promise.all([pushStatus(), AsyncStorage.getItem(PROMPT_KEY)]);
      if (alive) setShow(s === 'undetermined' && !dismissed);
    })().catch(() => {});
    return () => {
      alive = false;
    };
  }, []);

  if (!show) return null;
  const close = () => {
    setShow(false);
    AsyncStorage.setItem(PROMPT_KEY, '1').catch(() => {});
  };
  return (
    <View style={{ borderRadius: 12, borderWidth: 1, borderColor: colors.line, padding: 14, gap: 8 }}>
      <Text style={{ color: colors.ink, fontWeight: '700' }}>Quer saber quando a votação abrir?</Text>
      <Sub>Avisamos sobre votação, resultado e conquistas. Dá para mudar depois em Minha conta.</Sub>
      <View style={{ flexDirection: 'row', gap: 8 }}>
        <View style={{ flex: 1 }}>
          <Button
            title="Ativar avisos"
            loading={busy}
            onPress={async () => {
              setBusy(true);
              await enablePush().catch(() => {});
              setBusy(false);
              close();
            }}
          />
        </View>
        <View style={{ flex: 1 }}>
          <Button title="Agora não" kind="secondary" onPress={close} />
        </View>
      </View>
    </View>
  );
}
