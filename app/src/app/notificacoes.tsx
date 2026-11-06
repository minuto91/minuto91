// V8.4 — E14: Central de Notificações. Feed único (sem abas por categoria), agrupado em Hoje / Ontem / Esta semana /
// Anteriores, mais recentes primeiro. Lido/não lido é do servidor e só muda depois da confirmação dele. Abrir a lista
// não marca nada; ler um aviso NÃO resolve votação, convite ou pendência (a Central de Atenção é independente).
import { useIsFocused } from 'expo-router';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { FlatList, Pressable, RefreshControl, View } from 'react-native';

import { Notice, Skeleton } from '../lib/central';
import { loadNotificationsPage, markAllNotificationsRead, markNotificationRead } from '../lib/notifdata';
import { type Loaded, useBlock } from '../lib/centraldata';
import { friendly } from '../lib/errors';
import { classifyError } from '../lib/loadstate';
import { haptic } from '../lib/motion';
import { useGo } from '../lib/nav';
import { groupNotifs, markAllRead, markRead, mergePage, type Notif, notifPath, notifText, whenLabel } from '../lib/notifs';
import { useAuth } from '../lib/session';
import { Text } from '../lib/text';
import { colors, layout as L, type } from '../lib/theme';
import { Button, EmptyState } from '../lib/ui';

type Page = { items: Notif[]; next: unknown };

type Local = { sync: number | null; extra: Notif[]; next: unknown; reads: Record<string, string>; allAt: string | null };
const emptyLocal = (sync: number | null): Local => ({ sync, extra: [], next: undefined, reads: {}, allAt: null });

type Row = { kind: 'header'; key: string; label: string } | { kind: 'item'; key: string; n: Notif };

export default function Notificacoes() {
  const { session } = useAuth();
  const uid = session?.user.id ?? '';
  const focused = useIsFocused();
  const go = useGo();
  const [reload, setReload] = useState(0);
  const first = useBlock<Page>({ uid, scope: 'notifs', load: () => loadNotificationsPage(null) as Promise<Loaded<Page>>, reload });
  // Acréscimos locais (próximas páginas, leituras confirmadas) valem só sobre a leitura do servidor em que nasceram;
  // uma leitura nova os descarta, sem emendar páginas de leituras diferentes.
  const [local, setLocal] = useState<Local>(emptyLocal(null));
  const [mount] = useState(() => Date.now());
  const [more, setMore] = useState<'idle' | 'loading'>('idle');
  const [msg, setMsg] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const moreLock = useRef(false);
  const seen = useRef(false);

  const mine = local.sync === first.syncedAt ? local : emptyLocal(first.syncedAt);
  // Atualização funcional: duas confirmações seguidas não se sobrescrevem; se a leitura mudou no meio, descarta.
  const sync = first.syncedAt;
  const patch = useCallback((fn: (m: Local) => Local) => setLocal((prev) => fn(prev.sync === sync ? prev : emptyLocal(sync))), [sync]);
  const next = mine.next === undefined ? (first.data?.next ?? null) : mine.next;
  const items = useMemo(() => {
    const merged = mergePage(first.data?.items ?? [], mine.extra);
    const withAll = mine.allAt ? markAllRead(merged, mine.allAt) : merged;
    return Object.entries(mine.reads).reduce((cur, [id, at]) => markRead(cur, id, at), withAll);
  }, [first.data, mine.extra, mine.allAt, mine.reads]);
  const now = first.syncedAt ?? mount;

  // Voltar a esta tela relê (um aviso pode ter sido lido em outro lugar).
  useEffect(() => {
    if (!focused) return;
    if (seen.current) setReload((n) => n + 1);
    seen.current = true;
  }, [focused]);

  const offline = first.status === 'offline_cached' || first.status === 'offline_uncached';
  const canWrite = !offline && !first.stale;

  const open = useCallback(
    async (n: Notif) => {
      setMsg(null);
      const path = notifPath(n);
      // Marcar como lido só vale depois do servidor confirmar (sem falso sucesso).
      if (!n.read_at && canWrite) {
        markNotificationRead(n.id)
          .then((readAt) => patch((m) => ({ ...m, reads: { ...m.reads, [n.id]: readAt } })))
          .catch(() => {});
      }
      if (path) go(path as never);
      else setMsg('Este aviso não tem uma tela para abrir.');
    },
    [go, canWrite, patch],
  );

  async function markAll() {
    if (busy || !canWrite) return;
    setBusy(true);
    setMsg(null);
    try {
      const at = await markAllNotificationsRead();
      patch((m) => ({ ...m, allAt: at }));
      haptic.success();
    } catch (e) {
      setMsg(friendly((e as Error).message));
    }
    setBusy(false);
  }

  async function loadMore() {
    if (!next || moreLock.current || !canWrite) return;
    moreLock.current = true;
    setMore('loading');
    try {
      const page = await loadNotificationsPage(next);
      if (page.data) {
        const got = page.data;
        patch((m) => ({ ...m, extra: mergePage(m.extra, got.items), next: got.next ?? null }));
      }
    } catch (e) {
      setMsg(classifyError(e) === 'offline' ? 'Sem conexão. Não foi possível carregar mais avisos.' : friendly((e as Error).message));
    }
    moreLock.current = false;
    setMore('idle');
  }

  const groups = groupNotifs(items, now);
  const rows: Row[] = groups.flatMap((g) => [
    { kind: 'header' as const, key: `h-${g.key}`, label: g.label },
    ...g.items.map((n) => ({ kind: 'item' as const, key: n.id, n })),
  ]);
  const hasUnread = items.some((n) => !n.read_at);

  const header = (
    <View style={{ gap: 12, marginBottom: 8 }}>
      <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
        <Text style={{ ...type.title, flex: 1 }} accessibilityRole="header">
          Notificações
        </Text>
        <Pressable
          onPress={markAll}
          disabled={!hasUnread || !canWrite || busy}
          accessibilityRole="button"
          accessibilityState={{ disabled: !hasUnread || !canWrite || busy, busy }}
          style={{ minHeight: 44, justifyContent: 'center', opacity: hasUnread && canWrite ? 1 : 0.4 }}>
          <Text style={{ color: colors.blue, fontWeight: '700', fontSize: 14 }}>Marcar todas como lidas</Text>
        </Pressable>
      </View>
      {offline && first.data ? <Notice tone="warn">Sem conexão. Você vê os avisos salvos neste aparelho; marcar como lido exige conexão.</Notice> : null}
      {!offline && first.stale && first.data ? <Notice tone="warn">Alguns avisos podem estar desatualizados. Puxe para atualizar.</Notice> : null}
      {msg ? <Notice tone="info">{msg}</Notice> : null}
    </View>
  );

  return (
    <FlatList
      style={{ backgroundColor: colors.screen }}
      contentContainerStyle={{ alignSelf: 'center', width: '100%', maxWidth: L.maxWidth, padding: L.gutter, flexGrow: 1 }}
      data={rows}
      keyExtractor={(r) => r.key}
      ListHeaderComponent={header}
      refreshControl={
        <RefreshControl
          refreshing={first.refreshing}
          onRefresh={() => setReload((n) => n + 1)}
          tintColor={colors.blue}
          colors={[colors.blue]}
        />
      }
      onEndReached={loadMore}
      onEndReachedThreshold={0.5}
      renderItem={({ item }) =>
        item.kind === 'header' ? (
          <Text style={{ ...type.section, fontSize: 15, marginTop: 14, marginBottom: 4 }} accessibilityRole="header">
            {item.label}
          </Text>
        ) : (
          <NotifRow n={item.n} now={now} onPress={() => open(item.n)} />
        )
      }
      ListEmptyComponent={
        first.status === 'loading' ? (
          <View style={{ gap: 12 }} accessibilityLabel="Carregando os avisos">
            <Skeleton height={64} />
            <Skeleton height={64} />
            <Skeleton height={64} />
          </View>
        ) : first.status === 'empty_confirmed' || (first.status === 'loaded' && items.length === 0) ? (
          <EmptyState title="Nenhum aviso por enquanto" hint="Os avisos dos últimos 90 dias aparecem aqui." />
        ) : first.status === 'offline_uncached' ? (
          <EmptyState title="Sem conexão" hint="Não há avisos salvos neste aparelho. Conecte-se para ver os seus avisos.">
            <Button title="Tentar de novo" kind="secondary" onPress={() => setReload((n) => n + 1)} />
          </EmptyState>
        ) : first.status === 'session_expired' ? (
          <EmptyState title="Sua sessão expirou" hint="Entre de novo para ver os seus avisos." />
        ) : (
          <EmptyState title="Não foi possível carregar os avisos" hint={first.error ?? undefined}>
            <Button title="Tentar de novo" kind="secondary" onPress={() => setReload((n) => n + 1)} />
          </EmptyState>
        )
      }
      ListFooterComponent={
        <View style={{ gap: 8, marginTop: 12 }}>
          {more === 'loading' ? <Skeleton height={48} /> : null}
          <Text style={type.meta}>Os avisos ficam disponíveis por 90 dias. Ler um aviso não resolve votações, convites nem pendências.</Text>
        </View>
      }
    />
  );
}

function NotifRow({ n, now, onPress }: { n: Notif; now: number; onPress: () => void }) {
  const t = notifText(n);
  const unread = !n.read_at;
  const when = whenLabel(n.created_at, now);
  return (
    <Pressable
      onPress={onPress}
      accessibilityRole="button"
      accessibilityLabel={`${t.title}. ${t.body}. ${unread ? 'Não lida' : 'Lida'}. ${when}.`}
      style={({ pressed }) => ({
        flexDirection: 'row',
        alignItems: 'flex-start',
        gap: 12,
        minHeight: 64,
        paddingVertical: 12,
        borderBottomWidth: 1,
        borderBottomColor: colors.line,
        opacity: pressed ? 0.6 : 1,
      })}>
      <View style={{ width: 10, paddingTop: 7 }}>
        {unread ? <View style={{ width: 10, height: 10, borderRadius: 5, backgroundColor: colors.gold }} /> : null}
      </View>
      <View style={{ flex: 1, minWidth: 0, gap: 2 }}>
        <Text style={{ fontSize: 16, lineHeight: 22, fontWeight: unread ? '800' : '600', color: colors.ink }} numberOfLines={2}>
          {t.title}
        </Text>
        <Text style={type.caption} numberOfLines={3}>
          {t.body}
        </Text>
      </View>
      <Text style={{ ...type.meta, paddingTop: 3 }}>{when}</Text>
    </Pressable>
  );
}
