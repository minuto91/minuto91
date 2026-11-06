// V8.4 — E13: Perfil → Personalizar Central. Personalização limitada: só Próxima Rodada, Último Jogo e Resumo da
// Carreira se reordenam e se ocultam; Minhas Peladas só se oculta (e fica sempre por último). Os demais blocos são
// obrigatórios e não aparecem aqui como opção. A preferência é do usuário, vale em todos os aparelhos, é versionada no
// servidor e só é dada como salva depois da confirmação dele (offline não simula gravação).
import { useMemo, useState } from 'react';
import { Pressable, Switch, View } from 'react-native';

import { Icon } from '../lib/icons';
import { Notice } from '../lib/central';
import { loadLayout, useBlock } from '../lib/centraldata';
import { confirm } from '../lib/dialog';
import { friendly } from '../lib/errors';
import { haptic } from '../lib/motion';
import { useUnsavedGuard } from '../lib/nav';
import { useAuth } from '../lib/session';
import { supabase } from '../lib/supabase';
import { Text } from '../lib/text';
import { colors, type } from '../lib/theme';
import { Button, ErrorText, LoadingBlock, Screen, Sub, Title } from '../lib/ui';
import { type BlockId, type Layout, moveBlock, normalizeLayout, sameLayout, toggleHidden } from '../lib/v84logic';

const LABEL: Record<BlockId, { title: string; hint: string }> = {
  next_round: { title: 'Próxima Rodada', hint: 'A próxima escalação planejada em que você está.' },
  last_game: { title: 'Último Jogo', hint: 'A última partida que você disputou e foi publicada.' },
  career_summary: { title: 'Resumo da Carreira', hint: 'Seus números principais na pelada ativa.' },
  my_peladas: { title: 'Minhas Peladas', hint: 'Atalho para suas outras peladas. Fica sempre por último.' },
};

export default function PersonalizarCentral() {
  const { session } = useAuth();
  const uid = session?.user.id ?? '';
  const [reload, setReload] = useState(0);
  const block = useBlock<unknown>({ uid, scope: 'layout', load: loadLayout, reload });
  const server = useMemo<Layout | null>(() => (block.data ? normalizeLayout(block.data) : null), [block.data]);
  // Alterações em andamento; sem elas, a tela mostra exatamente o que o servidor tem.
  const [edit, setEdit] = useState<Layout | null>(null);
  const draft = edit ?? server;
  const [busy, setBusy] = useState<'save' | 'reset' | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [ok, setOk] = useState<string | null>(null);

  const offline = block.status === 'offline_cached' || block.status === 'offline_uncached';
  const writable = !!server && !offline && !block.stale;
  const dirty = !!edit && !!server && !sameLayout(edit, server);
  useUnsavedGuard(dirty && !busy);

  async function salvar() {
    if (!draft || !server || busy) return;
    setBusy('save');
    setMsg(null);
    setOk(null);
    const { error } = await supabase.rpc('set_central_layout', { p_order: draft.order, p_hidden: draft.hidden, p_expected_version: server.version });
    setBusy(null);
    if (error) {
      setMsg(friendly(error.message));
      // Conflito de versão: busca a atual; o rascunho local é descartado em favor do servidor.
      if (error.message.includes('LAYOUT_VERSION_CONFLICT')) {
        setEdit(null);
        setReload((n) => n + 1);
      }
      return;
    }
    haptic.success();
    setOk('Personalização salva.');
    setEdit(null);
    setReload((n) => n + 1);
  }

  function restaurar() {
    confirm('Restaurar o padrão?', 'A Central volta à ordem original, com todos os blocos visíveis.', 'Restaurar', async () => {
      setBusy('reset');
      setMsg(null);
      setOk(null);
      const { error } = await supabase.rpc('reset_central_layout');
      setBusy(null);
      if (error) return setMsg(friendly(error.message));
      haptic.success();
      setEdit(null);
      setOk('Padrão restaurado.');
      setReload((n) => n + 1);
    });
  }

  if (block.status === 'loading') {
    return (
      <Screen>
        <LoadingBlock />
      </Screen>
    );
  }
  if (!draft || !server) {
    return (
      <Screen>
        <Title>Personalizar Central</Title>
        <ErrorText>{block.status === 'offline_uncached' ? 'Sem conexão. Conecte-se para personalizar a Central.' : (block.error ?? 'Não foi possível carregar a sua personalização.')}</ErrorText>
        <Button title="Tentar de novo" kind="secondary" onPress={() => setReload((n) => n + 1)} />
      </Screen>
    );
  }

  return (
    <Screen>
      <Title>Personalizar Central</Title>
      <Sub>Escolha a ordem e o que aparece na sua tela inicial. Vale para todos os seus aparelhos.</Sub>
      {offline || block.stale ? <Notice tone="warn">Sem conexão ou sem confirmação do servidor: não é possível salvar agora.</Notice> : null}
      <ErrorText>{msg}</ErrorText>
      {ok && (
        <Text style={{ color: colors.ink, fontWeight: '600' }} accessibilityLiveRegion="polite">
          {ok}
        </Text>
      )}

      <View>
        {draft.order.map((id, i) => {
          const hidden = draft.hidden.includes(id);
          return (
            <View key={id} style={{ gap: 6, paddingVertical: 6, borderTopWidth: i ? 1 : 0, borderTopColor: colors.line }}>
              <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
                <View style={{ flex: 1 }}>
                  <Text style={{ ...type.cardTitle, opacity: hidden ? 0.5 : 1 }}>{LABEL[id].title}</Text>
                  <Text style={type.meta}>{hidden ? 'Oculto' : LABEL[id].hint}</Text>
                </View>
                <Switch
                  value={!hidden}
                  onValueChange={() => setEdit({ ...draft, hidden: toggleHidden(draft.hidden, id) })}
                  trackColor={{ true: colors.blue, false: colors.line }}
                  thumbColor={colors.white}
                  ios_backgroundColor={colors.line}
                  accessibilityLabel={`Mostrar ${LABEL[id].title}`}
                />
              </View>
              <View style={{ flexDirection: 'row', gap: 8 }}>
                <MoveButton label={`Subir ${LABEL[id].title}`} glyph="subir" disabled={i === 0} onPress={() => setEdit({ ...draft, order: moveBlock(draft.order, id, -1) })} />
                <MoveButton label={`Descer ${LABEL[id].title}`} glyph="descer" disabled={i === draft.order.length - 1} onPress={() => setEdit({ ...draft, order: moveBlock(draft.order, id, 1) })} />
              </View>
            </View>
          );
        })}
      </View>

      <Sub>Sempre visíveis: seu cabeçalho, a escolha da pelada, votações perto do fim, o Card e “Precisa de atenção”.</Sub>

      <Button title="Salvar" onPress={salvar} loading={busy === 'save'} disabled={!dirty || !writable || !!busy} />
      <Button title="Restaurar padrão" kind="secondary" onPress={restaurar} loading={busy === 'reset'} disabled={server.version === 0 || !writable || !!busy} />
      {dirty && <Button title="Descartar alterações" kind="ghost" onPress={() => setEdit(null)} />}
    </Screen>
  );
}

function MoveButton({ label, glyph, disabled, onPress }: { label: string; glyph: 'subir' | 'descer'; disabled: boolean; onPress: () => void }) {
  return (
    <Pressable
      onPress={() => {
        haptic.select();
        onPress();
      }}
      disabled={disabled}
      accessibilityRole="button"
      accessibilityLabel={label}
      accessibilityState={{ disabled }}
      style={{ minHeight: 44, minWidth: 44, alignItems: 'center', justifyContent: 'center', borderRadius: 12, borderWidth: 1, borderColor: colors.line, backgroundColor: colors.white, opacity: disabled ? 0.35 : 1 }}>
      <Icon name={glyph} size={22} color={colors.blue} />
    </Pressable>
  );
}
