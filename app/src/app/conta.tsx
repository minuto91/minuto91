import { useRouter } from 'expo-router';
import { useEffect, useState } from 'react';
import { Share, View } from 'react-native';
import { Text } from '../lib/text';

import { Avatar, pickAndUploadAvatar, removeAvatar } from '../lib/avatar';
import { confirm as confirmDialog } from '../lib/dialog';
import { friendly } from '../lib/errors';
import { LEGAL_VERSIONS } from '../lib/legalText';
import { loadMyProfile, type MyProfile, VISIBILITY, type Visibility } from '../lib/profile';
import { NotificationSettings } from '../lib/push';
import { signOut, useAuth } from '../lib/session';
import { supabase } from '../lib/supabase';
import { colors, FEET, type Foot } from '../lib/theme';
import { Block, Body, Button, Card, Chips, ErrorText, Input, ListGroup, ListRow, Screen, Sub, Title } from '../lib/ui';

type Blocked = { user_id: string; name: string };

const visLabel = (v: Visibility) => VISIBILITY.find((x) => x.value === v)?.label ?? v;
const fmtDay = (iso: string) => new Date(iso).toLocaleDateString('pt-BR');

export default function Conta() {
  const router = useRouter();
  const { session } = useAuth();
  const [me, setMe] = useState<MyProfile | null>(null);
  const [name, setName] = useState('');
  const [foot, setFoot] = useState<Foot | null>(null);
  const [purgeAfter, setPurgeAfter] = useState<string | null>(null);
  // V7.7 (055): 'recoverable' (30 dias) ou 'finalizing' (prazo vencido, exclusão em andamento; sem recuperação).
  const [canRecover, setCanRecover] = useState(true);
  // Quem vê meu perfil / minha carreira: valor salvo e valor em edição (null = ainda carregando).
  const [saved, setSaved] = useState<{ profile: Visibility; career: Visibility } | null>(null);
  const [profileVis, setProfileVis] = useState<Visibility>('peladas');
  const [careerVis, setCareerVis] = useState<Visibility>('peladas');
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
      const [{ data: st }, { data: bs }, mine] = await Promise.all([
        supabase.rpc('get_account_status'),
        supabase.from('user_blocks').select('blocked_user_id'),
        loadMyProfile().catch(() => null),
      ]);
      const ids = (bs ?? []).map((b) => b.blocked_user_id as string);
      // Nome que o bloqueado usa nas peladas em comum.
      const { data: ms } = ids.length
        ? await supabase.from('pelada_memberships').select('user_id, player_name').in('user_id', ids)
        : { data: [] };
      if (!alive) return;
      setPurgeAfter((st as { deletion_pending: boolean; purge_after: string | null })?.purge_after ?? null);
      setCanRecover((st as { can_recover?: boolean } | null)?.can_recover ?? true);
      if (mine) {
        setMe(mine);
        setName(mine.display_name);
        setFoot((mine.dominant_foot as Foot | null) ?? null);
        setSaved({ profile: mine.profile_visibility, career: mine.career_visibility });
        setProfileVis(mine.profile_visibility);
        setCareerVis(mine.career_visibility);
      }
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
    const r = await run<{ restored_memberships: number; not_restored?: { pelada_id: string }[] }>('recuperar', 'cancel_account_deletion');
    if (!r.ok) return;
    const blocked = r.data.not_restored?.length ?? 0;
    setOk(
      `Conta recuperada. Você voltou a ${r.data.restored_memberships} pelada(s), como jogador.` +
        (blocked ? ` ${blocked} pelada(s) estavam cheias antes da reserva de vaga: peça um convite ao administrador.` : ''),
    );
    setReload((n) => n + 1);
  }

  async function trocarFoto() {
    if (!session) return;
    setBusy('foto');
    setMsg(null);
    setOk(null);
    try {
      if (await pickAndUploadAvatar(session.user.id)) {
        setOk('Foto atualizada.');
        setReload((n) => n + 1);
      }
    } catch (e) {
      setMsg(e instanceof Error ? e.message : 'Não foi possível usar essa foto.');
    }
    setBusy(null);
  }

  function tirarFoto() {
    confirmDialog('Remover foto', 'Sua foto sai do perfil e dos Cards. Você pode pôr outra depois.', 'Remover', async () => {
      setBusy('remover');
      setMsg(null);
      setOk(null);
      try {
        await removeAvatar();
        setOk('Foto removida.');
        setReload((n) => n + 1);
      } catch (e) {
        setMsg((e as Error).message);
      }
      setBusy(null);
    });
  }

  async function salvarPerfil() {
    const r = await run('perfil', 'update_my_profile', { p_display_name: name, p_dominant_foot: foot });
    if (!r.ok) return;
    setOk('Perfil salvo.');
    setReload((n) => n + 1);
  }

  async function salvarPrivacidade() {
    const r = await run('privacidade', 'set_my_privacy', { p_profile: profileVis, p_career: careerVis });
    if (!r.ok) return;
    setOk('Privacidade salva. Vale na hora para o perfil e a carreira.');
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
          {canRecover ? (
            <>
              <Body>Sua conta será apagada em {fmtDay(purgeAfter)}.</Body>
              <Sub>
                Até lá, sua vaga em cada pelada fica reservada e você pode recuperar a conta e voltar com o seu histórico, como jogador.
              </Sub>
            </>
          ) : (
            <>
              <Body>O prazo de recuperação terminou e a exclusão está sendo concluída.</Body>
              <Sub>A conta fica bloqueada até o fim. Os resultados oficiais das partidas continuam, sem o seu nome.</Sub>
            </>
          )}
        </Card>
        <ErrorText>{msg}</ErrorText>
        {canRecover && <Button title="Recuperar minha conta" onPress={recuperar} loading={busy === 'recuperar'} />}
        <Button title="Sair da conta" kind="secondary" onPress={signOut} />
      </Screen>
    );
  }

  return (
    <Screen>
      <ErrorText>{msg}</ErrorText>
      {ok && <Text style={{ color: colors.ink, fontWeight: '600' }}>{ok}</Text>}

      {me && (
        <>
          <Text style={section}>Meu perfil</Text>
          <Block>
            <View style={{ flexDirection: 'row', alignItems: 'center', gap: 12 }}>
              <Avatar path={me.avatar_path} name={me.display_name} size={64} />
              <View style={{ flex: 1, gap: 8 }}>
                <Sub>Aparece no perfil e nos Cards.</Sub>
                <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 8 }}>
                  <Button title={me.avatar_path ? 'Trocar foto' : 'Escolher foto'} kind="secondary" size="sm" onPress={trocarFoto} loading={busy === 'foto'} disabled={!!busy} />
                  {me.avatar_path && <Button title="Remover" kind="danger" size="sm" onPress={tirarFoto} loading={busy === 'remover'} disabled={!!busy} />}
                </View>
              </View>
            </View>
            <Body>Nome</Body>
            <Input value={name} onChangeText={setName} maxLength={80} autoCapitalize="words" placeholder="Seu apelido" />
            <Body>Pé dominante</Body>
            <Chips options={FEET} value={foot} onChange={(v) => setFoot(v === foot ? null : v)} />
            <Button
              title="Salvar"
              onPress={salvarPerfil}
              loading={busy === 'perfil'}
              disabled={(name.trim() === me.display_name && foot === me.dominant_foot) || !name.trim() || !!busy}
            />
          </Block>
        </>
      )}
      <Button title="Sair da conta" kind="secondary" onPress={signOut} />

      <Text style={section}>Notificações</Text>
      <Block>
        <NotificationSettings />
      </Block>

      <Text style={section}>Privacidade</Text>
      {saved && (
        <>
          <Block>
            <Body>Quem vê meu perfil</Body>
            <Sub>Pé dominante, suas peladas e conquistas. Agora: {visLabel(saved.profile)}.</Sub>
            <Chips options={VISIBILITY} value={profileVis} onChange={setProfileVis} />
            <Sub>{VISIBILITY.find((x) => x.value === profileVis)?.hint}</Sub>
          </Block>
          <Block>
            <Body>Quem vê minha carreira</Body>
            <Sub>Totais e histórico de todas as peladas. Agora: {visLabel(saved.career)}.</Sub>
            <Chips options={VISIBILITY} value={careerVis} onChange={setCareerVis} />
            <Sub>{VISIBILITY.find((x) => x.value === careerVis)?.hint}</Sub>
          </Block>
          <Button
            title="Salvar privacidade"
            onPress={salvarPrivacidade}
            loading={busy === 'privacidade'}
            disabled={(profileVis === saved.profile && careerVis === saved.career) || !!busy}
          />
          <Block>
            <Sub>
              Dentro de cada pelada, seu nome, foto, Card e estatísticas continuam visíveis para os colegas: a súmula, a votação e
              os rankings precisam deles. Quem você bloqueia (ou quem bloqueou você) não vê seu perfil nem sua carreira.
            </Sub>
            <Sub>
              Uma foto já aberta por alguém pode continuar na tela dele por até 15 minutos. Imagens que você compartilhou fora do
              app (Cards e artes) não podem ser apagadas ou recuperadas pelo Minuto 91 depois do envio.
            </Sub>
          </Block>
        </>
      )}
      <Block>
        <Body>Jogadores bloqueados</Body>
        <Sub>Quem você bloqueia não aparece com foto e perfil para você.</Sub>
        {blocked.length === 0 && <Sub>Ninguém bloqueado.</Sub>}
        {blocked.map((b) => (
          <Button key={b.user_id} title={`Desbloquear ${b.name}`} kind="secondary" onPress={() => desbloquear(b.user_id)} />
        ))}
      </Block>
      {/* A18: documentos oficiais sempre acessíveis depois do aceite. */}
      <Block>
        <Body>Documentos</Body>
        <ListGroup>
          <ListRow title="Termos de Uso" onPress={() => router.push('/termos')} />
          <ListRow title="Política de Privacidade" onPress={() => router.push('/privacidade')} />
        </ListGroup>
        <Sub>Versões aceitas: Termos {LEGAL_VERSIONS.terms}, Política {LEGAL_VERSIONS.privacy}.</Sub>
      </Block>

      <Text style={section}>Trocar de conta</Text>
      <Block>
        <Body>Levar meu histórico para outra conta</Body>
        <Sub>
          Gere um código aqui e use na conta nova (por exemplo, se trocar o jeito de entrar). O código vale 30 dias, funciona
          uma vez e mostra só agora: guarde como uma senha. Depois do uso, esta conta é desativada.
        </Sub>
        {code ? (
          <>
            <Text style={{ fontSize: 22, fontWeight: '900', color: colors.ink, textAlign: 'center', letterSpacing: 1 }}>
              {code}
            </Text>
            <Button title="Guardar o código" kind="secondary" onPress={() => Share.share({ message: code })} />
          </>
        ) : (
          <Button title="Gerar código de transferência" kind="secondary" onPress={gerarCodigo} loading={busy === 'gerar'} />
        )}
      </Block>

      <Block>
        <Body>Recebi um código</Body>
        <Sub>Funciona numa conta que ainda não está em nenhuma pelada.</Sub>
        <Input autoCapitalize="characters" placeholder="XXXX-XXXX-XXXX-XXXX" value={redeem} onChangeText={setRedeem} />
        <Button title="Usar código" onPress={usarCodigo} loading={busy === 'usar'} disabled={redeem.trim().length < 16} />
      </Block>

      <Text style={section}>Excluir conta</Text>
      <Block>
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
      </Block>
    </Screen>
  );
}

const section = { fontSize: 19, lineHeight: 25, fontWeight: '700' as const, color: colors.ink, marginTop: 10 };
