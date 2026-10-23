// V4.6: campo da Seleção da Rodada (protótipo aprovado em 23/10/2026). Gramado verde com faixas discretas, linhas
// brancas proporcionais, círculo central e áreas, detalhes em azul e dourado; cada jogador num marcador redondo com a
// foto, o nome e a posição, e a borda na cor do time em que ele jogou NAQUELA partida (cor escolhida na súmula, 049).
// Sem cor no time: borda branca neutra (nenhuma cor é inventada). Sem foto: iniciais. Assinatura 91’ pequena no canto
// de baixo, sem cobrir jogador. O algoritmo da Seleção (016) não muda: aqui só o desenho.
import { Image } from 'expo-image';
import { useEffect, useState } from 'react';
import { Pressable, View } from 'react-native';
import Svg, { Circle, Line, Path, Rect } from 'react-native-svg';

import { useArtImage } from './artload';
import { Avatar, initials } from './avatar';
import { BrandSymbol } from './brand';
import { friendly } from './errors';
import { supabase } from './supabase';
import { Text } from './text';
import { colors } from './theme';

/** Paleta fixa das cores dos times (mesmos códigos do banco, 049). */
export const TEAM_COLORS = [
  { value: 'azul', label: 'Azul', hex: '#1255C6' },
  { value: 'branco', label: 'Branco', hex: '#FFFFFF' },
  { value: 'preto', label: 'Preto', hex: '#1B1F24' },
  { value: 'vermelho', label: 'Vermelho', hex: '#D92D20' },
  { value: 'amarelo', label: 'Amarelo', hex: '#F5C518' },
  { value: 'laranja', label: 'Laranja', hex: '#F08A24' },
  { value: 'roxo', label: 'Roxo', hex: '#6E3FC6' },
  { value: 'rosa', label: 'Rosa', hex: '#E8508F' },
] as const;
export type TeamColor = (typeof TEAM_COLORS)[number]['value'];
export const teamHex = (c: string | null | undefined) => TEAM_COLORS.find((x) => x.value === c)?.hex ?? null;
export const teamColorLabel = (c: string | null | undefined) => TEAM_COLORS.find((x) => x.value === c)?.label ?? null;

export type FieldPlayer = {
  key: string;
  position: 'goalkeeper' | 'defender' | 'midfielder' | 'attacker';
  name: string | null; // null = vaga sem candidato (a Seleção não adapta posição)
  posLabel?: string | null; // sigla (GOL, ZAG...) quando houver
  photoPath?: string | null;
  photoUrl?: string | null; // já resolvida (vitrine)
  teamColor?: string | null; // hex da cor do time naquela partida
};

// 4-3-3 de baixo (goleiro) para cima (ataque), em % do campo.
const SPOTS: Record<FieldPlayer['position'], [number, number][]> = {
  attacker: [
    [17, 18],
    [50, 13],
    [83, 18],
  ],
  midfielder: [
    [24, 42],
    [50, 49],
    [76, 42],
  ],
  defender: [
    [13, 68],
    [37, 71],
    [63, 71],
    [87, 68],
  ],
  goalkeeper: [[50, 85]],
};

function Pitch({ w, h }: { w: number; h: number }) {
  const line = { stroke: '#FFFFFF', strokeOpacity: 0.85, strokeWidth: 0.55, fill: 'none' };
  return (
    <Svg width={w} height={h} viewBox="0 0 100 150" preserveAspectRatio="none" style={{ position: 'absolute', left: 0, top: 0 }}>
      <Rect x={0} y={0} width={100} height={150} fill="#2F8A41" />
      {[0, 30, 60, 90, 120].map((y) => (
        <Rect key={y} x={0} y={y} width={100} height={15} fill="#349547" />
      ))}
      <Rect x={5} y={5} width={90} height={140} {...line} />
      <Line x1={5} y1={75} x2={95} y2={75} {...line} />
      <Circle cx={50} cy={75} r={12} {...line} />
      <Rect x={24} y={5} width={52} height={21} {...line} />
      <Rect x={37} y={5} width={26} height={8} {...line} />
      <Path d="M41 26 A10 10 0 0 0 59 26" {...line} />
      <Rect x={24} y={124} width={52} height={21} {...line} />
      <Rect x={37} y={137} width={26} height={8} {...line} />
      <Path d="M41 124 A10 10 0 0 1 59 124" {...line} />
      <Circle cx={50} cy={75} r={0.9} fill="#FFFFFF" fillOpacity={0.85} />
      <Circle cx={50} cy={18} r={0.7} fill="#FFFFFF" fillOpacity={0.85} />
      <Circle cx={50} cy={132} r={0.7} fill="#FFFFFF" fillOpacity={0.85} />
      <Path d="M5 5 L8.5 5 L5 8.2 Z M95 5 L91.5 5 L95 8.2 Z M5 145 L8.5 145 L5 141.8 Z M95 145 L91.5 145 L95 141.8 Z" fill={colors.gold} />
    </Svg>
  );
}

function Photo({ p, size }: { p: FieldPlayer; size: number }) {
  // Vitrine: URL pronta. App: Avatar (assinatura do Storage, iniciais sem foto, e a captura espera carregar).
  const art = useArtImage(p.photoUrl ?? null);
  if (p.photoUrl) {
    return <Image source={{ uri: p.photoUrl }} style={{ width: size, height: size, borderRadius: size / 2 }} contentFit="cover" onLoad={art.done} onError={art.done} />;
  }
  if (p.photoPath) return <Avatar path={p.photoPath} name={p.name ?? ''} size={size} />;
  return (
    <View style={{ width: size, height: size, borderRadius: size / 2, backgroundColor: colors.white, alignItems: 'center', justifyContent: 'center' }}>
      <Text style={{ fontSize: size * 0.36, fontWeight: '800', color: colors.deepBlue }}>{initials(p.name ?? '?')}</Text>
    </View>
  );
}

/** O campo com os jogadores. width define a escala inteira (altura = 1,5 × largura). */
export function SelectionField({ players, width }: { players: FieldPlayer[]; width: number }) {
  const h = Math.round(width * 1.5);
  const k = width / 358;
  const marker = Math.max(34, Math.round(50 * k));
  const ring = Math.max(2, Math.round(3.5 * k));
  const boxW = Math.max(68, Math.round(90 * k)); // nome legível mesmo no campo pequeno da arte 4:5
  const used: Record<string, number> = {};
  return (
    <View
      style={{ width, height: h, borderRadius: Math.round(14 * k), overflow: 'hidden', borderWidth: 3, borderColor: colors.deepBlue }}
      accessibilityLabel={`Seleção da Rodada: ${players.filter((p) => p.name).map((p) => p.name).join(', ')}`}>
      <Pitch w={width - 6} h={h - 6} />
      {players.map((p) => {
        const i = used[p.position] ?? 0;
        used[p.position] = i + 1;
        const spot = SPOTS[p.position][i];
        if (!spot) return null;
        const [x, y] = spot;
        const border = p.teamColor ?? '#FFFFFF';
        return (
          <View
            key={p.key}
            style={{ position: 'absolute', left: `${x}%`, top: `${y}%`, width: boxW, marginLeft: -boxW / 2, marginTop: -marker / 2, alignItems: 'center', gap: 3 }}>
            {p.name ? (
              <View
                style={{
                  width: marker,
                  height: marker,
                  borderRadius: marker / 2,
                  borderWidth: ring,
                  borderColor: border,
                  backgroundColor: colors.white,
                  overflow: 'hidden',
                  alignItems: 'center',
                  justifyContent: 'center',
                  // contorno escuro fino: borda branca ou amarela continua visível no gramado
                  shadowColor: '#0B2A15',
                  shadowOpacity: 0.45,
                  shadowRadius: 4,
                  shadowOffset: { width: 0, height: 2 },
                  elevation: 3,
                }}>
                <Photo p={p} size={marker - ring * 2} />
              </View>
            ) : (
              <View style={{ width: marker, height: marker, borderRadius: marker / 2, borderWidth: 2, borderStyle: 'dashed', borderColor: '#FFFFFF', opacity: 0.7 }} />
            )}
            <View style={{ alignItems: 'center', backgroundColor: 'rgba(16, 54, 117, 0.92)', borderRadius: 6, paddingHorizontal: k < 0.8 ? 4 : 7, paddingVertical: 2, maxWidth: boxW }}>
              <Text style={{ fontSize: Math.max(10, Math.round(12 * k)), fontWeight: '700', color: colors.white }} numberOfLines={1}>
                {p.name ? shortName(p.name) : 'Vaga'}
              </Text>
              {!!p.posLabel && (
                <Text style={{ fontSize: Math.max(9, Math.round(10 * k)), fontWeight: '600', color: '#F3D98B' }} numberOfLines={1}>
                  {p.posLabel}
                </Text>
              )}
            </View>
          </View>
        );
      })}
      <View style={{ position: 'absolute', right: 8, bottom: 6, opacity: 0.95 }}>
        <BrandSymbol size={Math.max(16, Math.round(20 * k))} onDark />
      </View>
    </View>
  );
}

/** Legenda das cores dos times da partida (só os que têm cor). */
export function TeamLegend({ teams, onDark = false }: { teams: { name: string; color: string | null }[]; onDark?: boolean }) {
  const shown = teams.filter((t) => t.color);
  if (!shown.length) return null;
  return (
    <View style={{ flexDirection: 'row', flexWrap: 'wrap', justifyContent: 'center', gap: 14 }}>
      {shown.map((t) => (
        <View key={t.name} style={{ flexDirection: 'row', alignItems: 'center', gap: 6 }}>
          <View style={{ width: 12, height: 12, borderRadius: 6, backgroundColor: t.color!, borderWidth: 1, borderColor: onDark ? colors.white : colors.line }} />
          <Text style={{ fontSize: 13, color: onDark ? colors.white : colors.ink }}>{t.name}</Text>
        </View>
      ))}
    </View>
  );
}

// Nome curto no marcador: primeiro nome; com sobrenome, a inicial ("Bruno H.").
function shortName(n: string) {
  const parts = n.trim().split(/\s+/);
  if (parts.length === 1 || parts[0].length > 9) return parts[0];
  return `${parts[0]} ${parts[parts.length - 1][0]}.`;
}


/**
 * Cor dos times da partida (admin e assistentes; 049). Fica na súmula e, depois do resultado, na tela da partida:
 * escolher a cor não muda nada do jogo, só o desenho da Seleção. Tocar de novo na cor escolhida tira a cor.
 */
export function TeamColorPicker({
  matchId,
  teamA,
  teamB,
  onSaved,
}: {
  matchId: string;
  teamA: string;
  teamB: string;
  onSaved?: (c: { A: string | null; B: string | null }) => void;
}) {
  const [cur, setCur] = useState<{ A: string | null; B: string | null } | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    let alive = true;
    (async () => {
      const { data, error } = await supabase.from('matches').select('team_a_color, team_b_color').eq('id', matchId).maybeSingle();
      if (!alive) return;
      if (error) return setMsg('As cores dos times ainda não estão disponíveis neste servidor.');
      setCur({ A: data?.team_a_color ?? null, B: data?.team_b_color ?? null });
    })();
    return () => {
      alive = false;
    };
  }, [matchId]);

  async function pick(team: 'A' | 'B', c: string) {
    if (!cur || busy) return;
    const next = { ...cur, [team]: cur[team] === c ? null : c };
    if (next.A && next.A === next.B) return setMsg('Os dois times não podem ter a mesma cor.');
    setBusy(true);
    setMsg(null);
    const { error } = await supabase.rpc('set_match_team_colors', { p_match: matchId, p_team_a_color: next.A, p_team_b_color: next.B });
    setBusy(false);
    if (error) return setMsg(friendly(error.message));
    setCur(next);
    onSaved?.({ A: teamHex(next.A), B: teamHex(next.B) });
  }

  return (
    <View style={{ gap: 10 }}>
      <Text style={{ fontSize: 17, fontWeight: '600', color: colors.ink }}>Cor dos times</Text>
      <Text style={{ fontSize: 14, color: colors.muted }}>Usada na borda dos jogadores da Seleção da Rodada. Opcional.</Text>
      {(['A', 'B'] as const).map((t) => (
        <View key={t} style={{ gap: 6 }}>
          <Text style={{ fontSize: 14, fontWeight: '600', color: colors.ink }}>
            {t === 'A' ? teamA : teamB}
            {cur?.[t] ? ` · ${teamColorLabel(cur[t])}` : ' · sem cor'}
          </Text>
          <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 6 }}>
            {TEAM_COLORS.map((c) => {
              const on = cur?.[t] === c.value;
              const taken = cur?.[t === 'A' ? 'B' : 'A'] === c.value;
              return (
                <Pressable
                  key={c.value}
                  accessibilityRole="button"
                  accessibilityLabel={`${t === 'A' ? teamA : teamB}: ${c.label}${taken ? ' (cor do outro time)' : ''}`}
                  accessibilityState={{ selected: on, disabled: taken || !cur }}
                  disabled={taken || !cur || busy}
                  onPress={() => pick(t, c.value)}
                  style={{ width: 44, height: 44, alignItems: 'center', justifyContent: 'center', opacity: taken ? 0.25 : 1 }}>
                  <View
                    style={{
                      width: 32,
                      height: 32,
                      borderRadius: 16,
                      backgroundColor: c.hex,
                      borderWidth: on ? 3 : 1,
                      borderColor: on ? colors.deepBlue : colors.line,
                    }}
                  />
                </Pressable>
              );
            })}
          </View>
        </View>
      ))}
      {msg && <Text style={{ color: colors.danger, fontSize: 14 }}>{msg}</Text>}
    </View>
  );
}
