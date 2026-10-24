// Card do jogador: Modelo A, escudo moderno minimalista (aprovado pelo fundador em 22/10/2026).
// Uma única silhueta (topo com vértice central, laterais retas, base pontiaguda) para as três
// categorias; muda só o acabamento: bronze com contorno simples, prata com contorno duplo e recortes
// laterais, ouro com moldura em camadas e detalhes no topo e nas laterais.
// Camadas: corpo metálico (SVG) → foto → degradês, brilho e moldura (SVG) → textos (Views).
// A moldura fica por cima da foto, então ela recorta as laterais da foto sem máscara de imagem
// (a captura da web, html2canvas, não respeita máscara nem "cover"; por isso o recorte da foto
// quadrada também é feito à mão, com overflow).
// Tudo é desenhado em unidades de uma caixa 100 x 144; width muda a escala inteira.
import { Image } from 'expo-image';
import { useArtImage } from './artload';
import { View } from 'react-native';
import { Text } from './text';
import Svg, { ClipPath, Defs, Ellipse, G, Line, LinearGradient, Path, RadialGradient, Rect, Stop } from 'react-native-svg';

import { initials, useAvatarUrl } from './avatar';
import { Card as CardData, cardAttributes, cardOverall, isV2, TIER } from './career';
import { CrestView, useCrestUrl } from './crest';
import { positionLabel, positionSector, positionShort } from './theme';

const VB_W = 100;
const VB_H = 144;
export const CARD_RATIO = VB_H / VB_W;
export const CARD_W = 275;

type Pt = [number, number];

// Silhueta externa, no sentido horário a partir do vértice do topo.
const OUTER: Pt[] = [
  [50, 1.2],
  [98.5, 12],
  [98.5, 111],
  [50, 142.8],
  [1.5, 111],
  [1.5, 12],
];
const RADII = [2.5, 4, 5, 3, 5, 4];

// Polígono convexo encolhido d unidades para dentro (cada lado anda d na direção do interior).
function inset(pts: Pt[], d: number): Pt[] {
  const n = pts.length;
  const lines = pts.map((p, i) => {
    const q = pts[(i + 1) % n];
    const dx = q[0] - p[0];
    const dy = q[1] - p[1];
    const len = Math.hypot(dx, dy);
    const nx = -dy / len;
    const ny = dx / len;
    return { p: [p[0] + nx * d, p[1] + ny * d] as Pt, v: [dx, dy] as Pt };
  });
  return lines.map((l, i) => {
    const m = lines[(i + n - 1) % n];
    // Interseção da reta anterior (m) com a atual (l).
    const den = m.v[0] * l.v[1] - m.v[1] * l.v[0];
    const t = ((l.p[0] - m.p[0]) * l.v[1] - (l.p[1] - m.p[1]) * l.v[0]) / den;
    return [m.p[0] + m.v[0] * t, m.p[1] + m.v[1] * t] as Pt;
  });
}

// Caminho com cantos arredondados (curva no vértice).
function rounded(pts: Pt[], radii: number[]): string {
  const n = pts.length;
  const toward = (a: Pt, b: Pt, r: number): Pt => {
    const len = Math.hypot(b[0] - a[0], b[1] - a[1]);
    return [a[0] + ((b[0] - a[0]) / len) * r, a[1] + ((b[1] - a[1]) / len) * r];
  };
  const f = (x: number) => Math.round(x * 100) / 100;
  let d = '';
  pts.forEach((v, i) => {
    const a = toward(v, pts[(i + n - 1) % n], radii[i]);
    const b = toward(v, pts[(i + 1) % n], radii[i]);
    d += `${i === 0 ? 'M' : 'L'}${f(a[0])} ${f(a[1])} Q${f(v[0])} ${f(v[1])} ${f(b[0])} ${f(b[1])} `;
  });
  return `${d}Z`;
}

const shape = (d: number) => rounded(inset(OUTER, d), RADII.map((r) => Math.max(1, r - d * 0.6)));
const OUTER_PATH = shape(0);

// Acabamento por categoria. frame = degradê da moldura (escuro, claro, escuro); body = fundo
// metálico (claro no topo); dark = painel de baixo; light = textos sobre o painel; accent = siglas e
// filetes; ink = overall e posição sobre o metal; t = espessura da moldura.
const FINISH = {
  bronze: {
    frame: ['#5E3216', '#B07142', '#4A260F'],
    body: ['#F2C7A2', '#CB8B58', '#8E542D'],
    dark: '#22140A',
    light: '#FBEBDD',
    accent: '#E2A878',
    ink: '#2A170A',
    sheen: 0.1,
    t: 2.4,
  },
  prata: {
    frame: ['#4B5158', '#C3C9D0', '#3E434A'],
    body: ['#F8F9FB', '#CDD2D8', '#8C939C'],
    dark: '#15181D',
    light: '#F3F5F7',
    accent: '#C6CDD5',
    ink: '#15181D',
    sheen: 0.14,
    t: 3.2,
  },
  ouro: {
    frame: ['#6A4606', '#EDC75C', '#573904'],
    body: ['#FFF2C2', '#E9C35B', '#B5871F'],
    dark: '#1F1705',
    light: '#FFF4D6',
    accent: '#F0CB62',
    ink: '#1E1604',
    sheen: 0.18,
    t: 4,
  },
} as const;

type Tier = keyof typeof FINISH;

// Caminhos que dependem só da categoria: calculados uma vez.
const PATHS = Object.fromEntries(
  (Object.keys(FINISH) as Tier[]).map((tier) => {
    const t = FINISH[tier].t;
    return [tier, { inner: shape(t), mid: shape(t * 0.5), third: shape(t * 0.33), twoThirds: shape(t * 0.68), edge: shape(0.45) }];
  }),
) as Record<Tier, Record<'inner' | 'mid' | 'third' | 'twoThirds' | 'edge', string>>;

// Áreas da foto e do texto (unidades da caixa).
const PHOTO_TOP = 16;
const PHOTO_BOTTOM = 97;
const PANEL_FROM = 70; // onde o painel escuro começa a aparecer
const PANEL_SOLID = 95; // daqui para baixo o painel é sólido
const ROW_L = 16;
const ROW_R = 84;
const ROW_TOP = 108;
const ROW_BOTTOM = 120.5;

// V4.3: a sigla oficial (GOL, ZAG, LD...) quando a posição atual é do setor do Card; senão, o setor do Card
// (um Card de temporada antiga não muda de setor). Layout e fórmulas do Modelo A intactos.
const SECTOR_CODE: Record<string, string> = { goalkeeper: 'GOL', defender: 'DEF', midfielder: 'MEI', attacker: 'ATA' };
export const cardPosition = (card: CardData) =>
  card.position_code && positionSector(card.position_code) === card.position ? card.position_code : card.position;

function Back({ tier }: { tier: Tier }) {
  const f = FINISH[tier];
  const id = `m91${tier}`;
  return (
    <Svg width="100%" height="100%" viewBox={`0 0 ${VB_W} ${VB_H}`} style={{ position: 'absolute', top: 0, left: 0 }}>
      <Defs>
        <LinearGradient id={`${id}b`} x1="0" y1="0" x2="0" y2="1">
          <Stop offset="0" stopColor={f.body[0]} />
          <Stop offset="0.2" stopColor={f.body[0]} />
          <Stop offset="0.5" stopColor={f.body[1]} />
          <Stop offset="1" stopColor={f.body[2]} />
        </LinearGradient>
      </Defs>
      <Path d={PATHS[tier].inner} fill={`url(#${id}b)`} />
    </Svg>
  );
}

function Front({ tier }: { tier: Tier }) {
  const f = FINISH[tier];
  const p = PATHS[tier];
  const id = `m91${tier}`;
  const t = f.t;
  const cols = 5; // cinco atributos na carta antiga e na V5
  const colW = (ROW_R - ROW_L) / cols;
  return (
    <Svg width="100%" height="100%" viewBox={`0 0 ${VB_W} ${VB_H}`} style={{ position: 'absolute', top: 0, left: 0 }}>
      <Defs>
        <ClipPath id={`${id}c`}>
          <Path d={p.inner} />
        </ClipPath>
        <LinearGradient id={`${id}f`} x1="0" y1="0" x2="1" y2="1">
          <Stop offset="0" stopColor={f.frame[0]} />
          <Stop offset="0.45" stopColor={f.frame[1]} />
          <Stop offset="0.6" stopColor={f.frame[1]} />
          <Stop offset="1" stopColor={f.frame[2]} />
        </LinearGradient>
        <LinearGradient id={`${id}t`} x1="0" y1={PHOTO_TOP} x2="0" y2={PHOTO_TOP + 14} gradientUnits="userSpaceOnUse">
          <Stop offset="0" stopColor={f.body[0]} stopOpacity="1" />
          <Stop offset="1" stopColor={f.body[0]} stopOpacity="0" />
        </LinearGradient>
        <RadialGradient id={`${id}g`} cx="0.5" cy="0.5" r="0.5">
          <Stop offset="0" stopColor={f.body[0]} stopOpacity="0.95" />
          <Stop offset="0.6" stopColor={f.body[0]} stopOpacity="0.7" />
          <Stop offset="1" stopColor={f.body[0]} stopOpacity="0" />
        </RadialGradient>
        <LinearGradient id={`${id}d`} x1="0" y1={PANEL_FROM} x2="0" y2={PANEL_SOLID} gradientUnits="userSpaceOnUse">
          <Stop offset="0" stopColor={f.dark} stopOpacity="0" />
          <Stop offset="0.55" stopColor={f.dark} stopOpacity="0.75" />
          <Stop offset="1" stopColor={f.dark} stopOpacity="0.97" />
        </LinearGradient>
      </Defs>

      <G clipPath={`url(#${id}c)`}>
        {/* A foto some suavemente no metal do topo e no painel escuro de baixo. */}
        <Rect x="0" y={PHOTO_TOP - 0.5} width={VB_W} height="15" fill={`url(#${id}t)`} />
        {/* Halo do metal atrás do overall e do escudo, para lerem bem sobre qualquer foto. */}
        <Ellipse cx="19" cy="27" rx="21" ry="20" fill={`url(#${id}g)`} />
        <Ellipse cx="82.5" cy="25.5" rx="17" ry="16" fill={`url(#${id}g)`} />
        {/* Brilho metálico: duas faixas diagonais discretas, que somem sob o painel escuro. */}
        <Path d="M58 0 L76 0 L22 144 L4 144 Z" fill="#FFFFFF" fillOpacity={f.sheen} />
        <Path d="M82 0 L88 0 L34 144 L28 144 Z" fill="#FFFFFF" fillOpacity={f.sheen * 0.7} />
        <Rect x="0" y={PANEL_FROM} width={VB_W} height={PANEL_SOLID - PANEL_FROM} fill={`url(#${id}d)`} />
        <Rect x="0" y={PANEL_SOLID - 0.1} width={VB_W} height={VB_H} fill={f.dark} fillOpacity="0.97" />
        {/* Linha sobre os atributos e separadores entre eles. */}
        <Line x1={ROW_L} y1={ROW_TOP - 2} x2={ROW_R} y2={ROW_TOP - 2} stroke={f.accent} strokeOpacity="0.75" strokeWidth="0.35" />
        {Array.from({ length: cols - 1 }, (_, i) => (
          <Line
            key={i}
            x1={ROW_L + colW * (i + 1)}
            y1={ROW_TOP + 1}
            x2={ROW_L + colW * (i + 1)}
            y2={ROW_BOTTOM - 1}
            stroke={f.accent}
            strokeOpacity="0.35"
            strokeWidth="0.3"
          />
        ))}
      </G>

      {/* Moldura: anel entre a silhueta externa e a interna. */}
      <Path d={`${OUTER_PATH} ${p.inner}`} fill={`url(#${id}f)`} fillRule="evenodd" />
      {/* Relevo: luz na borda de fora, sombra na de dentro. */}
      <Path d={p.edge} fill="none" stroke="#FFFFFF" strokeOpacity="0.35" strokeWidth="0.35" />
      <Path d={p.inner} fill="none" stroke={f.frame[2]} strokeOpacity="0.9" strokeWidth="0.45" />

      {tier === 'prata' && (
        <>
          {/* Contorno duplo: filete claro no meio da moldura. */}
          <Path d={p.mid} fill="none" stroke="#F4F6F8" strokeOpacity="0.85" strokeWidth="0.45" />
          {/* Recortes geométricos nas laterais. */}
          {[1.5, 98.5].map((x) => {
            const s = x < 50 ? 1 : -1;
            return (
              <Path
                key={x}
                d={`M${x} 52 L${x + s * t * 0.85} 55 L${x + s * t * 0.85} 63 L${x} 66 Z`}
                fill={f.frame[2]}
                stroke="#F4F6F8"
                strokeOpacity="0.6"
                strokeWidth="0.3"
              />
            );
          })}
        </>
      )}

      {tier === 'ouro' && (
        <>
          {/* Moldura em camadas: dois filetes. */}
          <Path d={p.third} fill="none" stroke="#FFF3C4" strokeOpacity="0.8" strokeWidth="0.4" />
          <Path d={p.twoThirds} fill="none" stroke={f.frame[2]} strokeOpacity="0.8" strokeWidth="0.4" />
          {/* Detalhe no topo: chevron que acompanha o vértice e uma pedra no centro. */}
          <Path
            d={`M30 ${12.6 + t} L50 ${8.3 + t} L70 ${12.6 + t}`}
            fill="none"
            stroke={f.frame[0]}
            strokeOpacity="0.55"
            strokeWidth="0.5"
            strokeLinejoin="round"
          />
          <Path d={`M50 ${1.6} L52.6 ${4.4} L50 ${7.2} L47.4 ${4.4} Z`} fill="#FFF3C4" stroke={f.frame[2]} strokeWidth="0.35" />
          {/* Acabamentos laterais: barras em relevo nas duas laterais. */}
          {[1.5, 98.5].map((x) => {
            const s = x < 50 ? 1 : -1;
            return (
              <G key={x}>
                {[
                  [26, 44],
                  [70, 88],
                ].map(([y1, y2]) => (
                  <Path
                    key={y1}
                    d={`M${x} ${y1} L${x + s * t * 0.9} ${y1 + 2} L${x + s * t * 0.9} ${y2 - 2} L${x} ${y2} Z`}
                    fill={f.frame[1]}
                    stroke={f.frame[2]}
                    strokeWidth="0.35"
                  />
                ))}
              </G>
            );
          })}
        </>
      )}
    </Svg>
  );
}

/** Card sem dados (só moldura e escudo), para a prévia do escudo antes de salvar. */
export function CrestSwatch({ tier, crestUrl, peladaName, width }: { tier: Tier; crestUrl: string | null; peladaName: string; width: number }) {
  const u = width / VB_W;
  return (
    <View style={{ width, height: Math.round(width * CARD_RATIO) }} accessibilityLabel={`Prévia do escudo no Card ${TIER[tier].label}`}>
      <Back tier={tier} />
      <Front tier={tier} />
      <View style={{ position: 'absolute', right: Math.round(8 * u), top: Math.round(17 * u) }}>
        <CrestView url={crestUrl} name={peladaName} size={Math.round(17 * u)} />
      </View>
    </View>
  );
}

/** Ano da temporada: o do início dela; sem data, um ano de 4 dígitos no nome; senão nada (o Card não inventa ano). */
export function seasonYear(start: string | null | undefined, name?: string | null): string | null {
  const fromStart = start?.match(/^(\d{4})-/)?.[1];
  if (fromStart) return fromStart;
  return name?.match(/\b(?:19|20)\d{2}\b/)?.[0] ?? null;
}

export function PlayerCard({
  card,
  playerName,
  photoPath,
  peladaName,
  crestPath,
  seasonName,
  seasonStart,
  width = CARD_W,
  photoUrl,
  crestUrl,
  mini = false,
}: {
  card: CardData;
  playerName: string;
  photoPath: string | null | undefined;
  peladaName: string;
  crestPath?: string | null;
  /** Nome da temporada (leitor de tela e retrocompatibilidade). */
  seasonName: string;
  /** Início da temporada (AAAA-MM-DD): o ano do rodapé. */
  seasonStart?: string | null;
  width?: number;
  /** URLs já resolvidas (vitrine de desenvolvimento); no app vêm de photoPath e crestPath. */
  photoUrl?: string | null;
  crestUrl?: string | null;
  /** Central 2.0: miniatura sem a linha de atributos (ilegível nesse tamanho; os atributos ficam em Minha Carreira). */
  mini?: boolean;
}) {
  const tier = card.tier as Tier;
  const f = FINISH[tier];
  const year = seasonYear(seasonStart, seasonName);
  const t = TIER[card.tier];
  const signedPhoto = useAvatarUrl(photoPath);
  const signedCrest = useCrestUrl(crestPath);
  const photo = photoUrl !== undefined ? photoUrl : signedPhoto;
  const art = useArtImage(photo ?? null); // A25: a arte espera a foto
  const crest = crestUrl !== undefined ? crestUrl : signedCrest;
  const u = width / VB_W; // px por unidade
  const height = Math.round(width * CARD_RATIO);
  const px = (n: number) => Math.round(n * u * 10) / 10;
  const font = (n: number) => Math.max(9, px(n));
  const compact = width < 200; // no Elenco: sem rodapé
  // V5: antes de 5 partidas não há OVR (sem número fictício): o canto mostra só "em avaliação".
  const overall = cardOverall(card);
  const attrs = cardAttributes(card);

  // Foto quadrada recortada à mão para cobrir a área (largura toda; sobra corta mais embaixo).
  const areaW = px(OUTER[1][0] - OUTER[5][0]); // só dentro da silhueta
  const areaH = px(PHOTO_BOTTOM - PHOTO_TOP);
  const side = areaW;
  const colW = (ROW_R - ROW_L) / attrs.length;
  // V6.1: com colunas estreitas demais para o texto mínimo de 9 px (Elenco em 320 px), a linha de atributos some
  // como na miniatura, em vez de sair cortada; os atributos continuam no Card completo.
  const showAttrs = !mini && px(colW) >= 24;

  return (
    <View
      accessibilityLabel={`Card ${t.label} de ${playerName}, ${overall === null ? 'em avaliação' : `overall ${overall}`},${positionLabel(cardPosition(card))}${card.is_provisional && overall !== null ? ', provisório' : ''}`}
      style={{ width, height }}>
      <Back tier={tier} />

      <View style={{ position: 'absolute', left: px(OUTER[5][0]), top: px(PHOTO_TOP), width: areaW, height: areaH, overflow: 'hidden' }}>
        {photo ? (
          <Image
            source={{ uri: photo }}
            style={{ position: 'absolute', left: 0, top: -Math.round((side - areaH) * 0.2), width: side, height: side }}
            contentFit="cover"
            accessibilityLabel={`Foto de ${playerName}`}
            onLoad={art.done}
            onError={art.done}
          />
        ) : (
          <View style={{ flex: 1, alignItems: 'center', paddingTop: px(16) }}>
            <Text style={{ fontSize: font(30), fontWeight: '800', color: f.ink, opacity: 0.35 }}>{initials(playerName)}</Text>
          </View>
        )}
      </View>

      <Front tier={tier} />

      {/* Overall e posição (alto à esquerda). */}
      <View style={{ position: 'absolute', left: px(7), top: px(16), width: px(24), alignItems: 'center' }}>
        <Text style={{ fontSize: font(15), lineHeight: font(16), fontWeight: '900', color: f.ink }}>{overall ?? '–'}</Text>
        <Text style={{ fontSize: font(6.2), fontWeight: '800', color: f.ink, letterSpacing: px(0.3) }}>
          {SECTOR_CODE[cardPosition(card)] ?? positionShort(cardPosition(card))}
        </Text>
        {card.is_provisional && !compact && (
          <Text style={{ fontSize: font(2.9), fontWeight: '800', color: f.ink, opacity: 0.75, marginTop: px(1) }}>{isV2(card) ? 'Em avaliação' : 'Provisório'}</Text>
        )}
      </View>

      {/* Escudo da pelada (alto à direita), proporção e transparência preservadas. */}
      <View style={{ position: 'absolute', right: px(8), top: px(17) }}>
        <CrestView url={crest} name={peladaName} size={px(17)} />
      </View>

      <Text
        style={{
          position: 'absolute',
          top: px(95),
          left: px(10),
          right: px(10),
          textAlign: 'center',
          fontSize: font(8.2),
          fontWeight: '800',
          color: f.light,
          letterSpacing: px(0.2),
        }}
        numberOfLines={1}
        adjustsFontSizeToFit
        minimumFontScale={0.6}>
        {playerName}
      </Text>

      {showAttrs && (
        <View style={{ position: 'absolute', top: px(ROW_TOP), left: px(ROW_L), width: px(ROW_R - ROW_L), flexDirection: 'row' }}>
          {attrs.map((a) => (
            <View key={a.key} style={{ width: px(colW), alignItems: 'center' }} accessibilityLabel={`${a.label} ${Math.round(Number(card[a.key]))}`}>
              <Text style={{ fontSize: font(3.9), fontWeight: '700', color: f.accent, letterSpacing: compact ? 0 : px(0.2) }}>{a.code}</Text>
              <Text style={{ fontSize: font(6.8), lineHeight: font(7.6), fontWeight: '800', color: f.light }}>{Math.round(Number(card[a.key]))}</Text>
            </View>
          ))}
        </View>
      )}

      {/* V4.6: o rodapé mostra só o ano da temporada do Card (sem "Temporada" e sem o nome da marca). */}
      {!compact && !!year && (
        <Text
          style={{
            position: 'absolute',
            top: px(123.2),
            left: px(30),
            right: px(30),
            textAlign: 'center',
            fontSize: font(4),
            fontWeight: '700',
            letterSpacing: px(0.6),
            color: f.accent,
          }}
          accessibilityLabel={`Temporada ${year}`}
          numberOfLines={1}>
          {year}
        </Text>
      )}
    </View>
  );
}
