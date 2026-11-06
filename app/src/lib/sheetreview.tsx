// REV-041: revisão compacta antes de publicar (ou de salvar uma correção): placar, participantes, estatísticas e
// possíveis problemas; numa correção, só as diferenças relevantes. As validações oficiais continuam no servidor.
import { View } from 'react-native';

import type { SheetPlayer } from './match';
import { Icon } from './icons';
import { Text } from './text';
import { colors, type } from './theme';
import { Button, Card } from './ui';

type Totals = { A: number; B: number };

export function sheetIssues(players: SheetPlayer[]) {
  const issues: string[] = [];
  for (const t of ['A', 'B'] as const) {
    const n = players.filter((p) => p.team === t).length;
    if (n === 0) issues.push(`Time ${t} sem jogadores.`);
    else if (!players.some((p) => p.team === t && (p.position === 'GOL' || p.position === 'goalkeeper')))
      issues.push(`Time ${t} sem goleiro de posição (dá para indicar um goleiro temporário depois).`);
  }
  if (players.some((p) => p.goals > 10)) issues.push('Alguém com mais de 10 gols: confira.');
  return issues;
}

export function sheetDiff(before: SheetPlayer[], after: SheetPlayer[], nameOf: (p: SheetPlayer) => string) {
  const b = new Map(before.map((p) => [p.key, p]));
  const a = new Map(after.map((p) => [p.key, p]));
  const out: string[] = [];
  for (const p of after) if (!b.has(p.key)) out.push(`Entrou: ${nameOf(p)}`);
  for (const p of before) if (!a.has(p.key)) out.push(`Saiu: ${nameOf(p)}`);
  for (const p of after) {
    const o = b.get(p.key);
    if (!o) continue;
    if (o.team !== p.team) out.push(`${nameOf(p)}: mudou de time`);
    if (o.goals !== p.goals) out.push(`${nameOf(p)}: gols ${o.goals} → ${p.goals}`);
    if (o.assists !== p.assists) out.push(`${nameOf(p)}: assistências ${o.assists} → ${p.assists}`);
    if ((o.reds ?? 0) !== (p.reds ?? 0) || (o.yellows ?? 0) !== (p.yellows ?? 0)) out.push(`${nameOf(p)}: cartões alterados`);
  }
  return out;
}

export function SheetReview({
  teamA, teamB, score, players, before, nameOf, correction, busy, onConfirm, onBack,
}: {
  teamA: string;
  teamB: string;
  score: Totals;
  players: SheetPlayer[];
  before: SheetPlayer[] | null;
  nameOf: (p: SheetPlayer) => string;
  correction: boolean;
  busy: boolean;
  onConfirm: () => void;
  onBack: () => void;
}) {
  const issues = sheetIssues(players);
  const diff = correction && before ? sheetDiff(before, players, nameOf) : [];
  const count = (t: 'A' | 'B') => players.filter((p) => p.team === t).length;
  const sum = (k: 'goals' | 'assists') => players.reduce((s, p) => s + p[k], 0);
  return (
    <Card>
      <Text style={[type.cardTitle, { textAlign: 'center' }]}>{`${teamA} ${score.A} – ${score.B} ${teamB}`}</Text>
      <Text style={[type.caption, { textAlign: 'center' }]}>
        {`${count('A')} × ${count('B')} jogadores · ${sum('goals')} gols de jogador · ${sum('assists')} assistências`}
      </Text>
      {correction && (
        <View style={{ gap: 2 }}>
          <Text style={[type.meta, { color: colors.ink }]}>Diferenças</Text>
          {diff.length === 0 ? <Text style={type.caption}>Nenhuma mudança de jogador ou estatística.</Text> : diff.map((d) => <Text key={d} style={type.bodySm}>{d}</Text>)}
          {diff.some((d) => d.startsWith('Entrou') || d.startsWith('Saiu')) && (
            <Text style={[type.caption, { color: colors.danger }]}>Mudar quem jogou pode reiniciar a votação.</Text>
          )}
        </View>
      )}
      {issues.map((i) => (
        <View key={i} style={{ flexDirection: 'row', alignItems: 'flex-start', gap: 6 }}>
          <Icon name="alerta" size={16} color={colors.darkGold} />
          <Text style={[type.caption, { color: colors.darkGold, flex: 1 }]}>{i}</Text>
        </View>
      ))}
      <Button title={correction ? 'Confirmar correção' : 'Confirmar e publicar'} loading={busy} onPress={onConfirm} />
      <Button title="Voltar e editar" kind="ghost" disabled={busy} onPress={onBack} />
    </Card>
  );
}
