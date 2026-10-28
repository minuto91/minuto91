// REV-008 / REV-048: "Será mensalista?" para quem entrou ou voltou. Até a decisão nada é cobrado;
// falha de rede deixa a classificação pendente (o servidor só grava com a resposta explícita do admin).
import { useRef, useState } from 'react';
import { View } from 'react-native';

import { friendly } from './errors';
import { centsToInput, formatBRL, parseBRL } from './money';
import { supabase } from './supabase';
import { Text } from './text';
import { colors, radius, type } from './theme';
import { Button, ErrorText, Input } from './ui';

export function BillingPrompt({ membershipId, name, defaultCents, onDone }: {
  membershipId: string; name: string; defaultCents: number | null; onDone: () => void;
}) {
  const [yes, setYes] = useState(false);
  const [value, setValue] = useState(defaultCents ? centsToInput(defaultCents) : '');
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const sending = useRef(false);
  const cents = parseBRL(value);

  async function send(monthly: boolean) {
    if (sending.current) return;
    sending.current = true;
    setBusy(true);
    setMsg(null);
    const { error } = await supabase.rpc('classify_member_billing', {
      p_membership: membershipId, p_monthly: monthly, p_amount_cents: monthly ? cents : null,
    });
    sending.current = false;
    setBusy(false);
    if (error) return setMsg(friendly(error.message)); // continua pendente
    onDone();
  }

  return (
    <View style={{ borderWidth: 1, borderColor: colors.line, borderRadius: radius.card, padding: 12, gap: 8 }}>
      <Text style={type.body}>{`${name} será mensalista?`}</Text>
      {yes ? (
        <>
          <Input keyboardType="decimal-pad" placeholder="Valor da mensalidade" value={value} onChangeText={setValue} />
          {cents ? <Text style={type.caption}>{`${formatBRL(cents)} por mês, a partir de hoje`}</Text> : null}
          <ErrorText>{msg}</ErrorText>
          <Button title="Salvar" loading={busy} disabled={!cents} onPress={() => send(true)} />
          <Button title="Voltar" kind="ghost" onPress={() => setYes(false)} />
        </>
      ) : (
        <>
          <ErrorText>{msg}</ErrorText>
          <View style={{ flexDirection: 'row', gap: 8 }}>
            <View style={{ flex: 1 }}>
              <Button title="Sim" kind="secondary" onPress={() => setYes(true)} />
            </View>
            <View style={{ flex: 1 }}>
              <Button title="Não" kind="secondary" loading={busy} onPress={() => send(false)} />
            </View>
          </View>
        </>
      )}
    </View>
  );
}
