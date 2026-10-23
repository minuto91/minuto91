import { useRouter } from 'expo-router';
import { useEffect, useState } from 'react';
import { Pressable, Share } from 'react-native';
import { Text } from '../lib/text';

import { friendly } from '../lib/errors';
import { LEGAL_VERSIONS } from '../lib/legalText';
import { NotificationSettings } from '../lib/push';
import { signOut } from '../lib/session';
import { supabase } from '../lib/supabase';
import { colors } from '../lib/theme';
import { Body, Button, Card, ErrorText, Input, Screen, Sub, Title } from '../lib/ui';

type Blocked = { user_id: string; name: string };

const fmtDay = (iso: string) => new Date(iso).toLocaleDateString('pt-BR');

export default function Conta() {
  const router = useRouter();
  const [purgeAfter, setPurgeAfter] = useState<string | null>(null);
  const [blocked, setBlocked] = useState<Blocked[]>([]);
  const [code, setCode] = useState<string | null>(null);
  const [redeem, setRedeem] = useState('');
  const [confirm, setConfirm] = useState('');
  const [reload, setReload] = useState(0);
  const [busy, setBusy] = useState<string | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [ok, setOk] = useState<string | null>(null);

  useEffect(() => {
    let alive = true;
    (async () => {
      const [{ data: st }, { data: bs }] = await Promise.all([
        supabase.rpc('get_account_status'),
        supabase.from('user_blocks').select('blocked_user_id'),
      ]);
      const ids = (bs ?? []).map((b) => b.blocked_user_id as string);
      // Nome que o bloqueado usa nas peladas em comum.
      const { data: ms } = ids.length
        ? await supabase.from('pelada_memberships').select('user_id, player_name').in('user_id', ids)
        : { data: [] };
      if (!alive) return;
      setPurgeAfter((st as { deletion_pending: boolean; purge_after: string | null })?.purge_after ?? null);
      setBlocked(ids.map((u) => ({ user_id: u, name: ms?.find((m) => m.user_id === u)?.player_name ?? 'Jogador' })));
    })();
    return () => {
      alive = false;
    };
  }, [reload]);

  async function run<T>(name: string, fn: string, args: Record<string, unknown> = {}) {
    setBusy(name);
    setMsg(null);
    setOk(null);
    const { data, error } = await supabase.rpc(fn, args);
    setBusy(null);
    if (error) setMsg(friendly(error.message));
    return { ok: !error, data: data as T };
  }

  async function gerarCodigo() {
    const r = await run<string>('gerar', 'create_transfer_code');
    if (r.ok) setCode(r.data);
  }

  async function usarCodigo() {
    const r = await run<{ peladas?: number; error?: string }>('usar', 'redeem_transfer_code', { p_code: redeem });
    if (!r.ok) return;
    if (r.data.error) return setMsg(friendly(r.data.error));
    setOk(`Histórico transferido: ${r.data.peladas} pelada(s). A conta antiga foi desativada.`);
    setRedeem('');
  }

  async function excluir() {
    const r = await run('excluir', 'request_account_deletion', { p_confirm: true });
    if (r.ok) setReload((n) => n + 1);
  }

  async function recuperar() {
    const r = await run<{ restored_memberships: number }>('recuperar', 'cancel_account_deletion');
    if (!r.ok) return;
    setOk(`Conta recuperada. Você voltou a ${r.data.restored_memberships} pelada(s), como jogador.`);
    setReload((n) => n + 1);
  }

  async function desbloquear(u: string) {
    const r = await run('bloqueio', 'unblock_user', { p_user: u });
    if (r.ok) setReload((n) => n + 1);
  }

  if (purgeAfter) {
    return (
      <Screen>
        <Title>Conta em exclusão</Title>
        <Card>
          <Body>Sua conta será apagada em {fmtDay(purgeAfter)}.</Body>
          <Sub>Até lá, você pode recuperar a conta e voltar às suas peladas com o seu histórico, como jogador.</Sub>
        </Card>
        <ErrorText>{msg}</ErrorText>
        <Button title="Recuperar minha conta" onPress={recuperar} loading={busy === 'recuperar'} />
        <Button title="Sair da conta" kind="secondary" onPress={signOut} />
      </Screen>
    );
  }

  return (
    <Screen>
      <Title>Minha conta</Title>
      <ErrorText>{msg}</ErrorText>
      {ok && <Text style={{ color: colors.deepBlue, fontWeight: '600' }}>{ok}</Text>}

      <Pressable onPress={() => router.push('/perfil')} accessibilityRole="button">
        <Card>
          <Body>Meu perfil ›</Body>
          <Sub>Foto, nome e pé dominante. A posição e o Card ficam em cada pelada.</Sub>
        </Card>
      </Pressable>
      <Button title="Sair da conta" kind="secondary" onPress={signOut} />

      <Text style={section}>Notificações</Text>
      <Card>
        <NotificationSettings />
      </Card>

      <Text style={section}>Privacidade</Text>
      <Card>
        <Body>Jogadores bloqueados</Body>
        <Sub>Quem você bloqueia não aparece com foto e perfil para você.</Sub>
        {blocked.length === 0 && <Sub>Ninguém bloqueado.</Sub>}
        {blocked.map((b) => (
          <Button key={b.user_id} title={`Desbloquear ${b.name}`} kind="secondary" onPress={() => desbloquear(b.user_id)} />
        ))}
      </Card>
      {/* A18: documentos oficiais sempre acessíveis depois do aceite. */}
      <Card>
        <Body>Documentos</Body>
        <Button title="Termos de Uso" kind="secondary" onPress={() => router.push('/termos')} />
        <Button title="Política de Privacidade" kind="secondary" onPress={() => router.push('/privacidade')} />
        <Sub>Versões aceitas: Termos {LEGAL_VERSIONS.terms}, Política {LEGAL_VERSIONS.privacy}.</Sub>
      </Card>

      <Text style={section}>Trocar de conta</Text>
      <Card>
        <Body>Levar meu histórico para outra conta</Body>
        <Sub>
          Gere um código aqui e use na conta nova (por exemplo, se trocar o jeito de entrar). O código vale 30 dias, funciona
          uma vez e mostra só agora: guarde como uma senha. Depois do uso, esta conta é desativada.
        </Sub>
        {code ? (
          <>
            <Text style={{ fontSize: 22, fontWeight: '900', color: colors.deepBlue, textAlign: 'center', letterSpacing: 1 }}>
              {code}
            </Text>
            <Button title="Guardar o código" kind="secondary" onPress={() => Share.share({ message: code })} />
          </>
        ) : (
          <Button title="Gerar código de transferência" kind="secondary" onPress={gerarCodigo} loading={busy === 'gerar'} />
        )}
      </Card>

      <Card>
        <Body>Recebi um código</Body>
        <Sub>Funciona numa conta que ainda não está em nenhuma pelada.</Sub>
        <Input autoCapitalize="characters" placeholder="XXXX-XXXX-XXXX-XXXX" value={redeem} onChangeText={setRedeem} />
        <Button title="Usar código" onPress={usarCodigo} loading={busy === 'usar'} disabled={redeem.trim().length < 16} />
      </Card>

      <Text style={section}>Excluir conta</Text>
      <Card>
        <Body>Excluir minha conta</Body>
        <Sub>
          Você vira &ldquo;Aposentado&rdquo; nas peladas na hora: sai das votações, a administração passa para outra pessoa e seu
          perfil some para os outros. Por 30 dias dá para recuperar; depois, a conta e os dados pessoais são apagados. Assinaturas
          da App Store ou Google Play não são canceladas por aqui.
        </Sub>
        <Input autoCapitalize="characters" placeholder='digite EXCLUIR para confirmar' value={confirm} onChangeText={setConfirm} />
        <Button
          title="Excluir minha conta"
          kind="danger"
          onPress={excluir}
          loading={busy === 'excluir'}
          disabled={confirm.trim().toUpperCase() !== 'EXCLUIR'}
        />
      </Card>
    </Screen>
  );
}

const section = { fontSize: 19, lineHeight: 25, fontWeight: '700' as const, color: colors.deepBlue, marginTop: 10 };
