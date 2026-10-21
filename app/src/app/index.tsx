import AsyncStorage from '@react-native-async-storage/async-storage';
import { useFocusEffect, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { Pressable, Text, View } from 'react-native';

import { useAuth } from '../lib/session';
import { supabase } from '../lib/supabase';
import { colors } from '../lib/theme';
import { Body, Button, Card, ErrorText, Screen, Sub } from '../lib/ui';

type Row = { id: string; name: string; role: string };

export default function Home() {
  const { session } = useAuth();
  const router = useRouter();
  const [rows, setRows] = useState<Row[] | null>(null);
  const [err, setErr] = useState<string | null>(null);

  useFocusEffect(
    useCallback(() => {
      let alive = true;
      (async () => {
        // Convite recebido antes do login: continua de onde parou.
        const pending = await AsyncStorage.getItem('pending_invite');
        if (pending) {
          await AsyncStorage.removeItem('pending_invite');
          router.push({ pathname: '/convite/[token]', params: { token: pending } });
          return;
        }
        if (!session) return;
        const { data: ms, error } = await supabase
          .from('pelada_memberships')
          .select('role, pelada_id')
          .eq('user_id', session.user.id)
          .eq('status', 'active');
        if (!alive) return;
        if (error) return setErr(error.message);
        const ids = (ms ?? []).map((m) => m.pelada_id);
        if (!ids.length) return setRows([]);
        const { data: ps, error: e2 } = await supabase.from('peladas').select('id, name').in('id', ids);
        if (!alive) return;
        if (e2) return setErr(e2.message);
        setErr(null);
        setRows(
          (ps ?? []).map((p) => ({
            id: p.id,
            name: p.name,
            role: ms!.find((m) => m.pelada_id === p.id)?.role ?? 'player',
          })),
        );
      })();
      return () => {
        alive = false;
      };
    }, [session, router]),
  );

  return (
    <Screen>
      <ErrorText>{err}</ErrorText>
      {rows === null ? (
        <Sub>Carregando...</Sub>
      ) : rows.length === 0 ? (
        <Card>
          <Body>Você ainda não está em nenhuma pelada.</Body>
          <Sub>Crie a sua ou entre com um convite.</Sub>
        </Card>
      ) : (
        rows.map((r) => (
          <Pressable
            key={r.id}
            onPress={() => router.push({ pathname: '/pelada/[id]', params: { id: r.id } })}>
            <Card>
              <Text style={{ fontSize: 18, fontWeight: '700', color: colors.deepBlue }}>{r.name}</Text>
              <Sub>{r.role === 'admin' ? 'Administrador' : r.role === 'assistant' ? 'Assistente' : 'Jogador'}</Sub>
            </Card>
          </Pressable>
        ))
      )}
      <View style={{ height: 8 }} />
      <Button title="Criar pelada" onPress={() => router.push('/criar-pelada')} />
      <Button title="Entrar com convite" kind="secondary" onPress={() => router.push('/entrar')} />
      <Button title="Premium" kind="secondary" onPress={() => router.push('/premium')} />
      <Button title="Sair da conta" kind="secondary" onPress={() => supabase.auth.signOut()} />
    </Screen>
  );
}
