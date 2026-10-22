import { useRouter } from 'expo-router';
import { useEffect, useState } from 'react';
import { Switch, Text, View } from 'react-native';

import { friendly } from '../lib/errors';
import { LEGAL_VERSIONS } from '../lib/legalText';
import { signOut, useAuth } from '../lib/session';
import { supabase } from '../lib/supabase';
import { colors } from '../lib/theme';
import { Button, ErrorText, Input, Screen, Sub, Title } from '../lib/ui';

// Cadastro inicial (18+, apelido, Termos e Privacidade) ou, para quem já tem conta, só o aceite de uma
// versão nova dos documentos (A18). A09: o campo vem com o nome atual (Google/Apple ou o já salvo); vazio
// mantém esse nome (nunca o pedaço do e-mail), e o apelido também chega às peladas.
export default function Onboarding() {
  const { refresh } = useAuth();
  const router = useRouter();
  const [loaded, setLoaded] = useState(false);
  const [returning, setReturning] = useState(false); // já cadastrado: só os documentos novos
  const [nome, setNome] = useState('');
  const [adulto, setAdulto] = useState(false);
  const [termos, setTermos] = useState(false);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);

  useEffect(() => {
    let alive = true;
    (async () => {
      const { data } = await supabase.rpc('get_my_profile');
      if (!alive) return;
      const p = data as { display_name?: string; adult_declared_at?: string | null } | null;
      setNome(p?.display_name && p.display_name !== 'Jogador' ? p.display_name : '');
      setReturning(!!p?.adult_declared_at);
      setLoaded(true);
    })();
    return () => {
      alive = false;
    };
  }, []);

  async function concluir() {
    setBusy(true);
    setMsg(null);
    if (!returning) {
      const { error } = await supabase.rpc('complete_onboarding', { p_display_name: nome.trim() || null, p_adult: adulto, p_terms: termos });
      if (error) {
        setBusy(false);
        return setMsg(friendly(error.message));
      }
    }
    const { error } = await supabase.rpc('accept_legal_documents', {
      p_terms_version: LEGAL_VERSIONS.terms,
      p_privacy_version: LEGAL_VERSIONS.privacy,
    });
    // Banco sem a migração 037: o aceite fica só com a data no perfil (como antes).
    if (error && !/accept_legal_documents|function/i.test(error.message)) {
      setBusy(false);
      return setMsg(friendly(error.message));
    }
    await refresh();
    setBusy(false);
  }

  if (!loaded) {
    return (
      <Screen>
        <Sub>Carregando...</Sub>
      </Screen>
    );
  }

  return (
    <Screen>
      {returning ? (
        <>
          <Title>Documentos atualizados</Title>
          <Sub>Os Termos de Uso ou a Política de Privacidade mudaram. Leia e aceite para continuar.</Sub>
        </>
      ) : (
        <>
          <Title>Como te chamam na pelada?</Title>
          <Sub>Esse apelido aparece nos seus Cards e rankings.</Sub>
          <Input autoCapitalize="words" placeholder="seu apelido" value={nome} onChangeText={setNome} maxLength={80} />
          <Row value={adulto} onChange={setAdulto} label="Declaro que tenho 18 anos ou mais." />
        </>
      )}
      <View style={{ gap: 4 }}>
        <Text style={{ color: colors.blue, fontWeight: '600', paddingVertical: 10 }} onPress={() => router.push('/termos')} accessibilityRole="link">
          Ler os Termos de Uso (versão {LEGAL_VERSIONS.terms}) ›
        </Text>
        <Text style={{ color: colors.blue, fontWeight: '600', paddingVertical: 10 }} onPress={() => router.push('/privacidade')} accessibilityRole="link">
          Ler a Política de Privacidade (versão {LEGAL_VERSIONS.privacy}) ›
        </Text>
      </View>
      <Row value={termos} onChange={setTermos} label="Li e aceito os Termos de Uso e a Política de Privacidade." />
      <ErrorText>{msg}</ErrorText>
      <Button title="Continuar" onPress={concluir} loading={busy} disabled={(!returning && !adulto) || !termos} />
      <Button title="Sair" kind="secondary" onPress={signOut} />
    </Screen>
  );
}

function Row({ value, onChange, label }: { value: boolean; onChange: (v: boolean) => void; label: string }) {
  return (
    <View style={{ flexDirection: 'row', alignItems: 'center', gap: 10, minHeight: 44 }}>
      <Switch value={value} onValueChange={onChange} trackColor={{ true: colors.blue }} accessibilityLabel={label} />
      <Text style={{ flex: 1, color: colors.ink }}>{label}</Text>
    </View>
  );
}
