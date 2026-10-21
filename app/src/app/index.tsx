import { useState } from 'react';
import { Button, ScrollView, Text, TextInput, View } from 'react-native';
import { supabase } from '../lib/supabase';

export default function Teste() {
  const [email, setEmail] = useState('');
  const [senha, setSenha] = useState('');
  const [nome, setNome] = useState('');
  const [log, setLog] = useState<string[]>([]);
  const add = (m: string) => setLog((l) => [m, ...l]);

  async function cadastrar() {
    const { error } = await supabase.auth.signUp({ email, password: senha });
    add(error ? 'cadastro ERRO: ' + error.message : 'cadastro OK');
  }
  async function entrar() {
    const { error } = await supabase.auth.signInWithPassword({ email, password: senha });
    add(error ? 'login ERRO: ' + error.message : 'login OK');
  }
  async function onboarding() {
    const { error } = await supabase.rpc('complete_onboarding', {
      p_display_name: nome || 'Jogador',
      p_adult: true,
      p_terms: true,
    });
    add(error ? 'onboarding ERRO: ' + error.message : 'onboarding OK');
  }
  async function criarPelada() {
    const { data, error } = await supabase.rpc('create_pelada', {
      p_name: 'Pelada Teste',
      p_position: 'midfielder',
    });
    add(error ? 'pelada ERRO: ' + error.message : 'pelada criada: ' + data);
  }
  async function sair() {
    await supabase.auth.signOut();
    add('saiu');
  }

  return (
    <ScrollView contentContainerStyle={{ padding: 24, paddingTop: 70, gap: 10 }}>
      <Text style={{ fontSize: 22, fontWeight: '700' }}>Minuto 91 - teste</Text>
      <TextInput placeholder="e-mail" autoCapitalize="none" keyboardType="email-address"
        value={email} onChangeText={setEmail}
        style={{ borderWidth: 1, padding: 10, borderRadius: 6 }} />
      <TextInput placeholder="senha (6+ caracteres)" secureTextEntry
        value={senha} onChangeText={setSenha}
        style={{ borderWidth: 1, padding: 10, borderRadius: 6 }} />
      <TextInput placeholder="seu apelido" value={nome} onChangeText={setNome}
        style={{ borderWidth: 1, padding: 10, borderRadius: 6 }} />
      <Button title="1. Cadastrar" onPress={cadastrar} />
      <Button title="2. Entrar" onPress={entrar} />
      <Button title="3. Onboarding (18+ e termos)" onPress={onboarding} />
      <Button title="4. Criar pelada" onPress={criarPelada} />
      <Button title="Sair" onPress={sair} />
      <View style={{ marginTop: 12 }}>
        {log.map((l, i) => <Text key={i}>{l}</Text>)}
      </View>
    </ScrollView>
  );
}
