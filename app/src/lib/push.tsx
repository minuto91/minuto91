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
import { useRouter } from 'expo-router';
import { useEffect, useState } from 'react';
import { Platform, Switch, Text, View } from 'react-native';

import { friendly } from './errors';
import { supabase } from './supabase';
import { colors } from './theme';
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
      importance: Notifications.AndroidImportance.HIGH,
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

// Só caminhos do próprio app (o servidor manda o caminho; mesmo assim conferimos aqui).
const UUID = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
const SAFE_PATH = new RegExp(`^/(partida/${UUID}|pelada/${UUID}(/(retrospectiva|rankings))?|conta)?$`, 'i');

/** Montado só quando pushSupported: abre a tela do aviso tocado e acompanha a troca de token. */
export function PushHandler() {
  const router = useRouter();
  const response = Notifications.useLastNotificationResponse();

  useEffect(() => {
    if (!response || response.actionIdentifier !== Notifications.DEFAULT_ACTION_IDENTIFIER) return;
    const path = response.notification.request.content.data?.path;
    Notifications.clearLastNotificationResponse();
    if (typeof path === 'string' && SAFE_PATH.test(path)) router.push(path as never);
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

type Prefs = { essential: boolean; engagement: boolean };

/** Minha conta > Notificações: estado deste aparelho e as duas preferências (valem para todos os aparelhos). */
export function NotificationSettings() {
  const [status, setStatus] = useState<PushStatus | null>(null);
  const [prefs, setPrefs] = useState<Prefs | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    let alive = true;
    (async () => {
      const [s, { data }] = await Promise.all([pushStatus(), supabase.from('notification_preferences').select('essential, engagement').maybeSingle()]);
      if (!alive) return;
      setStatus(s);
      setPrefs((data as Prefs | null) ?? { essential: true, engagement: true });
    })();
    return () => {
      alive = false;
    };
  }, []);

  async function save(next: Prefs) {
    const before = prefs;
    setPrefs(next);
    setMsg(null);
    const { error } = await supabase.rpc('set_notification_preferences', { p_essential: next.essential, p_engagement: next.engagement });
    if (error) {
      setPrefs(before);
      setMsg(error.code === 'PGRST202' ? 'Preferências ainda indisponíveis neste servidor (falta a migração 035).' : friendly(error.message));
    }
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
        <Sub>Os avisos no celular funcionam no app instalado pela loja (ou na versão de teste instalada). Aqui eles não chegam.</Sub>
      )}
      {status === 'denied' && <Sub>Os avisos estão bloqueados nos ajustes do celular. Libere em Ajustes &gt; Minuto 91 &gt; Notificações.</Sub>}
      {status === 'undetermined' && <Button title="Ativar avisos neste celular" onPress={ativar} loading={busy} />}
      {status === 'granted' && <Text style={{ color: colors.deepBlue, fontWeight: '600' }}>Avisos ativados neste celular.</Text>}
      {prefs && (
        <>
          <Row
            label="Votações, resultados e avisos da pelada"
            hint="Votação aberta e perto de fechar, resultado, partida anulada, mudanças de função."
            value={prefs.essential}
            onChange={(v) => save({ ...prefs, essential: v })}
          />
          <Row
            label="Conquistas e novidades"
            hint="Prêmios, figurinhas e retrospectiva. No máximo 3 por semana."
            value={prefs.engagement}
            onChange={(v) => save({ ...prefs, engagement: v })}
          />
        </>
      )}
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
