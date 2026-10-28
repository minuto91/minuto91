import { useRouter } from 'expo-router';
import { useRef, useState } from 'react';
import { Pressable, View } from 'react-native';

import { CrestDraft, CrestView, pickCrest, uploadCrest } from '../lib/crest';
import { DraftBanner } from '../lib/draftbanner';
import { Toggle } from '../lib/toggle';
import { clearDraft, draftKey, useDraft } from '../lib/drafts';
import { friendly } from '../lib/errors';
import { requestId } from '../lib/ids';
import { useAuth } from '../lib/session';
import { supabase } from '../lib/supabase';
import { Text } from '../lib/text';
import { colors, type } from '../lib/theme';
import { Button, Chips, ErrorText, Input, PositionPicker, Screen, Section, Sub, Title } from '../lib/ui';

// REV-006: criação em cinco etapas. Os dados ficam no rascunho (REV-044) e a criação é única (request_id).
const STEPS = ['Identidade', 'Times', 'Agenda', 'Configurações', 'Revisão'] as const;
const COLORS = ['azul', 'branco', 'preto', 'vermelho', 'amarelo', 'laranja', 'roxo', 'rosa'] as const;
const SWATCH: Record<string, string> = {
  azul: '#1255C6', branco: '#FFFFFF', preto: '#15243B', vermelho: '#C62828',
  amarelo: '#F2C230', laranja: '#EF7D22', roxo: '#6A3FB5', rosa: '#E0569B',
};
const WEEKDAYS = ['Dom', 'Seg', 'Ter', 'Qua', 'Qui', 'Sex', 'Sáb'];
const DURATIONS = [
  { value: '120', label: '2 horas' },
  { value: '240', label: '4 horas' },
  { value: '360', label: '6 horas' },
] as const;

type Form = {
  step: number;
  name: string;
  location: string;
  position: string | null;
  teamA: string;
  teamB: string;
  colorA: string | null;
  colorB: string | null;
  weekday: number | null;
  time: string;
  duration: '120' | '240' | '360';
  cards: boolean;
  bolaMurcha: boolean;
  requestId: string;
};

const blank = (): Form => ({
  step: 0, name: '', location: '', position: null, teamA: '', teamB: '', colorA: null, colorB: null,
  weekday: null, time: '', duration: '240', cards: false, bolaMurcha: true, requestId: requestId(),
});

const validTime = (t: string) => t === '' || /^([01]\d|2[0-3]):[0-5]\d$/.test(t);

export default function CriarPelada() {
  const router = useRouter();
  const { session } = useAuth();
  const key = session ? draftKey(session.user.id, 'criar-pelada') : null;
  const d = useDraft<Form>(key, blank());
  const f = d.value;
  const set = (p: Partial<Form>) => d.setValue({ ...f, ...p });
  const [crest, setCrest] = useState<CrestDraft | null>(null);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const sending = useRef(false);

  const stepOk = [
    f.name.trim().length >= 2 && !!f.position,
    !(f.colorA && f.colorB && f.colorA === f.colorB),
    validTime(f.time),
    true,
    true,
  ];

  async function criar() {
    if (sending.current) return;
    sending.current = true;
    setBusy(true);
    setMsg(null);
    const { data, error } = await supabase.rpc('create_pelada_wizard', {
      p: {
        name: f.name.trim(), position: f.position, location: f.location.trim(),
        team_a_name: f.teamA.trim(), team_b_name: f.teamB.trim(), team_a_color: f.colorA, team_b_color: f.colorB,
        weekday: f.weekday, time: f.time || null, voting_duration_minutes: Number(f.duration),
        cards_tracking: f.cards, bola_murcha_enabled: f.bolaMurcha,
      },
      p_request_id: f.requestId,
    });
    if (error) {
      sending.current = false;
      setBusy(false);
      return setMsg(friendly(error.message)); // campos preservados; tentar de novo usa o mesmo request_id
    }
    const id = String(data);
    if (crest) {
      try {
        await uploadCrest(id, crest);
      } catch {
        // O escudo pode ser enviado depois em Configurações > Identidade; a pelada já existe.
      }
    }
    if (key) await clearDraft(key);
    setBusy(false);
    router.replace({ pathname: '/pelada/[id]/convidar', params: { id, novo: '1' } });
  }

  if (d.pending) {
    return (
      <Screen>
        <Title>Nova pelada</Title>
        <DraftBanner onResume={d.resume} onDiscard={d.discard} />
      </Screen>
    );
  }

  return (
    <Screen>
      <View style={{ flexDirection: 'row', gap: 4 }} accessibilityLabel={`Etapa ${f.step + 1} de 5: ${STEPS[f.step]}`}>
        {STEPS.map((s, i) => (
          <View key={s} style={{ flex: 1, height: 4, borderRadius: 2, backgroundColor: i <= f.step ? colors.blue : colors.line }} />
        ))}
      </View>
      <Sub>{`${f.step + 1}/5 · ${STEPS[f.step]}`}</Sub>

      {f.step === 0 && (
        <>
          <View style={{ flexDirection: 'row', alignItems: 'center', gap: 14 }}>
            <Pressable
              onPress={async () => setCrest((await pickCrest()) ?? crest)}
              accessibilityRole="button"
              accessibilityLabel="Escolher escudo">
              <CrestView url={crest?.uri ?? null} name={f.name || 'M91'} size={64} />
            </Pressable>
            <View style={{ flex: 1 }}>
              <Input autoCapitalize="sentences" placeholder="Nome da pelada" value={f.name} onChangeText={(name) => set({ name })} maxLength={100} />
            </View>
          </View>
          <Input autoCapitalize="sentences" placeholder="Local (opcional)" value={f.location} onChangeText={(location) => set({ location })} maxLength={120} />
          <Section>Sua posição</Section>
          <PositionPicker value={f.position} onChange={(position) => set({ position })} />
        </>
      )}

      {f.step === 1 && (
        <>
          {(['A', 'B'] as const).map((t) => {
            const color = t === 'A' ? f.colorA : f.colorB;
            const other = t === 'A' ? f.colorB : f.colorA;
            return (
              <View key={t} style={{ gap: 8 }}>
                <Input
                  autoCapitalize="sentences"
                  placeholder={`Time ${t}`}
                  value={t === 'A' ? f.teamA : f.teamB}
                  onChangeText={(v) => set(t === 'A' ? { teamA: v } : { teamB: v })}
                  maxLength={40}
                />
                <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 8 }}>
                  {COLORS.map((c) => {
                    const on = color === c;
                    const taken = other === c;
                    return (
                      <Pressable
                        key={c}
                        disabled={taken}
                        onPress={() => set(t === 'A' ? { colorA: on ? null : c } : { colorB: on ? null : c })}
                        accessibilityRole="radio"
                        accessibilityState={{ selected: on, disabled: taken }}
                        accessibilityLabel={c}
                        style={{ width: 44, height: 44, alignItems: 'center', justifyContent: 'center', opacity: taken ? 0.25 : 1 }}>
                        <View
                          style={{
                            width: 30, height: 30, borderRadius: 15, backgroundColor: SWATCH[c],
                            borderWidth: on ? 3 : 1, borderColor: on ? colors.blue : colors.line,
                          }}
                        />
                      </Pressable>
                    );
                  })}
                </View>
              </View>
            );
          })}
        </>
      )}

      {f.step === 2 && (
        <>
          <Section first>Dia</Section>
          <Chips
            options={WEEKDAYS.map((w, i) => ({ value: String(i), label: w }))}
            value={f.weekday === null ? null : String(f.weekday)}
            onChange={(v) => set({ weekday: f.weekday === Number(v) ? null : Number(v) })}
          />
          <Section>Horário</Section>
          <Input placeholder="20:00" keyboardType="numbers-and-punctuation" value={f.time} onChangeText={(time) => set({ time })} maxLength={5} />
          {!validTime(f.time) && <ErrorText>Use o formato 20:00.</ErrorText>}
        </>
      )}

      {f.step === 3 && (
        <>
          <Section first>Prazo da votação</Section>
          <Chips options={DURATIONS} value={f.duration} onChange={(duration) => set({ duration })} />
          <Toggle label="Registro de cartões" value={f.cards} onChange={(cards) => set({ cards })} />
          <Toggle label="Bola Murcha" premium value={f.bolaMurcha} onChange={(bolaMurcha) => set({ bolaMurcha })} />
          <Sub>Recursos Premium dependem do plano da pelada (R$ 29,90/mês).</Sub>
        </>
      )}

      {f.step === 4 && (
        <View style={{ gap: 8 }}>
          <Row k="Nome" v={f.name.trim()} />
          {f.location.trim() ? <Row k="Local" v={f.location.trim()} /> : null}
          <Row k="Sua posição" v={f.position ?? '—'} />
          <Row k="Times" v={`${f.teamA.trim() || 'Time A'} × ${f.teamB.trim() || 'Time B'}`} />
          <Row k="Agenda" v={f.weekday === null ? 'Sem dia fixo' : `${WEEKDAYS[f.weekday]}${f.time ? ` · ${f.time}` : ''}`} />
          <Row k="Votação" v={DURATIONS.find((x) => x.value === f.duration)?.label ?? ''} />
          <Row k="Cartões" v={f.cards ? 'Registrados' : 'Não registrados'} />
        </View>
      )}

      <ErrorText>{msg}</ErrorText>
      <View style={{ flexDirection: 'row', gap: 8, marginTop: 'auto' }}>
        {f.step > 0 && (
          <View style={{ flex: 1 }}>
            <Button title="Voltar" kind="secondary" disabled={busy} onPress={() => set({ step: f.step - 1 })} />
          </View>
        )}
        <View style={{ flex: 1 }}>
          {f.step < 4 ? (
            <Button title="Continuar" disabled={!stepOk[f.step]} onPress={() => set({ step: f.step + 1 })} />
          ) : (
            <Button title="Criar pelada" loading={busy} disabled={!stepOk[0]} onPress={criar} />
          )}
        </View>
      </View>
    </Screen>
  );
}

function Row({ k, v }: { k: string; v: string }) {
  return (
    <View style={{ flexDirection: 'row', justifyContent: 'space-between', gap: 12, paddingVertical: 6, borderBottomWidth: 1, borderBottomColor: colors.line }}>
      <Text style={type.caption}>{k}</Text>
      <Text style={[type.body, { flexShrink: 1, textAlign: 'right' }]}>{v}</Text>
    </View>
  );
}
