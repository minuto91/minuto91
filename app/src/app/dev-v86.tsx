// Vitrine da V8.6: só em desenvolvimento. Mostra a tela do Craque da Temporada em cada estado, com DADOS SIMULADOS.
// Nunca lê o Supabase. Não é teste de integração.
import { useState } from 'react';

import { CraqueView, State } from '../lib/craqueview';

const C = [
  { membership_id: 'a', name: 'Rafael Silva', slot: 'ovr', substitute: false, ovr: 90.4, finalist: false },
  { membership_id: 'b', name: 'Bruno Costa', slot: 'goals', substitute: false, ovr: 71.2, finalist: false },
  { membership_id: 'c', name: 'Diego Lima', slot: 'craque', substitute: true, ovr: 85, finalist: false },
];
const BASE: State = { season_id: 's', status: 'round1', is_admin: false, round: 1, candidates: C, i_am_elector: true, my_vote: null };
const IN_3D = () => new Date(Date.now() + 2.5 * 86400000).toISOString();
const SCENES: Record<string, State> = {
  'Não aberta (admin pode abrir)': { ...BASE, status: 'not_started', round: null, is_admin: true, can_open: true },
  '1º turno (voto aberto)': { ...BASE, closes_at: IN_3D() },
  '1º turno (já votei, prorrogada)': { ...BASE, my_vote: 'b', extended: true, closes_at: IN_3D() },
  '2º turno (finalistas)': { ...BASE, status: 'round2', round: 2, candidates: C.map((c, i) => ({ ...c, finalist: i < 2 })), closes_at: IN_3D() },
  'Aguardando o admin': { ...BASE, status: 'awaiting_admin', round: null, is_admin: true, winner_membership_id: 'a' },
  'Publicado': { ...BASE, status: 'published', round: null, winner_membership_id: 'a' },
  'Sem quórum': { ...BASE, status: 'no_winner', round: null, no_winner_reason: 'sem_quorum' },
  'Empate bloqueado': { ...BASE, status: 'tie_blocked', round: null },
};

export default function DevV86() {
  const [scene, setScene] = useState(Object.keys(SCENES)[1]);
  const [now] = useState(() => Date.now());
  if (!__DEV__) return null;
  return (
    <CraqueView
      state={SCENES[scene]}
      seasons={Object.keys(SCENES).map((k) => ({ id: k, name: k }))}
      seasonId={scene}
      onSeason={setScene}
      busy={false}
      msg={null}
      now={now}
      onOpen={() => {}}
      onConfirm={() => {}}
      onVote={() => {}}
    />
  );
}
