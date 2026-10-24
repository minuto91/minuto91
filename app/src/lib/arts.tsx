// Artes oficiais para compartilhar (Brand Book 11: fundo branco, azul nos títulos, dourado só nas
// conquistas, logo discreta). Dois formatos: Stories 9:16 (1080 x 1920) e post 4:5 (1080 x 1350); cada
// arte se ajusta ao formato escolhido no painel (useArtFormat). Nada é publicado sozinho: o painel
// mostra a arte e só compartilha quando a pessoa toca.
// Quem monta cada arte decide se pode: notas só para quem vê as notas (RN-098); o pós-jogo, o Card
// e a figurinha só da própria pessoa. Sem números inventados: tudo vem do resultado oficial.
import { createContext, ReactNode, useContext, useRef, useState } from 'react';
import { StyleSheet, View } from 'react-native';
import { Text } from './text';

import { ArtImagesProvider, useArtTracker } from './artload';
import { Avatar } from './avatar';
import { Crest } from './crest';
import { Card as CardData, plural } from './career';
import { friendly } from './errors';
import { fmtRating } from './match';
import { CARD_W, PlayerCard } from './playercard';
import type { PeladaRetro, PlayerRetro } from './retro';
import { shareViewAsImage } from './share';
import { colors } from './theme';
import { BrandSignature } from './brand';
import { FieldPlayer, SelectionField, TeamLegend } from './selection';
import { StickerArtCode, StickerTile } from './stickers';
import { Button, Chips, ErrorText, Sub } from './ui';

// Largura que cabe na tela de um iPhone pequeno (375 - 2 x 20 de margem); a altura vem do formato.
const W = 315;
export type ArtFormat = 'story' | 'post';
const FORMATS = [
  { value: 'story', label: 'Stories 9:16' },
  { value: 'post', label: 'Post 4:5' },
] as const;
const SIZE: Record<ArtFormat, { h: number; width: number; height: number }> = {
  story: { h: 560, width: 1080, height: 1920 },
  post: { h: 394, width: 1080, height: 1350 },
};

const FormatContext = createContext<ArtFormat>('story');
/** Formato da arte que está sendo montada (para compactar no 4:5). */
export const useArtFormat = () => useContext(FormatContext);

export function SharePanel({
  label,
  fileName,
  title,
  children,
}: {
  label: string;
  fileName: string;
  title: string;
  children: ReactNode;
}) {
  const ref = useRef<View>(null);
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const [format, setFormat] = useState<ArtFormat>('story');
  const images = useArtTracker();

  async function compartilhar() {
    setBusy(true);
    setMsg(null);
    try {
      // A25: espera foto e escudo (até 5 s; o que não carregar sai com iniciais ou o escudo padrão).
      await new Promise((r) => setTimeout(r, 250));
      await images.idle(5000);
      await shareViewAsImage(ref, `${fileName}-${format === 'story' ? '9x16' : '4x5'}`, title, SIZE[format]);
    } catch (e) {
      setMsg(friendly((e as Error).message));
    }
    setBusy(false);
  }

  if (!open) return <Button title={label} kind="secondary" onPress={() => setOpen(true)} />;
  return (
    <View style={{ gap: 10 }}>
      <Chips options={FORMATS} value={format} onChange={setFormat} />
      <View style={{ alignItems: 'center' }}>
        <View
          ref={ref}
          collapsable={false}
          style={[s.frame, { height: SIZE[format].h, paddingVertical: format === 'story' ? 26 : 18, gap: format === 'story' ? 16 : 10 }]}>
          <ArtImagesProvider tracker={images}>
            <FormatContext.Provider value={format}>{children}</FormatContext.Provider>
          </ArtImagesProvider>
          <View style={{ flex: 1 }} />
          <View style={{ alignItems: 'center' }}>
            <BrandSignature size={18} />
          </View>
        </View>
      </View>
      <ErrorText>{msg}</ErrorText>
      <Button title="Compartilhar imagem" onPress={compartilhar} loading={busy} />
      <Sub>Ao compartilhar, a imagem sai do app e pode continuar acessível fora dele, mesmo se algo mudar aqui depois.</Sub>
      <Button title="Fechar" kind="secondary" onPress={() => setOpen(false)} />
    </View>
  );
}

// Com escudo (028), ele vem no topo; sem escudo, o escudo padrão com as iniciais.
export function Header({ title, subtitle, crestPath }: { title: string; subtitle: string; crestPath?: string | null }) {
  const post = useArtFormat() === 'post';
  return (
    <View style={{ alignItems: 'center', gap: 2 }}>
      {crestPath !== undefined && <Crest path={crestPath} name={title} size={post ? 34 : 44} />}
      <Text style={s.pelada} numberOfLines={1}>
        {title}
      </Text>
      <Text style={s.muted}>{subtitle}</Text>
    </View>
  );
}

function Score({ teamA, teamB, scoreA, scoreB }: { teamA: string; teamB: string; scoreA: number; scoreB: number }) {
  return (
    // Placar grande e os nomes embaixo (nomes de até 40 letras não espremem o placar).
    <View style={{ alignItems: 'center' }}>
      <Text style={s.score}>
        {scoreA} x {scoreB}
      </Text>
      <Text style={s.team} numberOfLines={2}>
        {teamA} x {teamB}
      </Text>
    </View>
  );
}

// ---------- Arte da partida ----------
// Só de partida finalizada (nada provisório). Craque da Partida só quando foi apurado oficialmente.
// Gols e assistências são da súmula oficial; as notas entram só para quem pode vê-las.

export type ResultArtData = {
  peladaName: string;
  crestPath?: string | null;
  date: string;
  teamA: string;
  teamB: string;
  scoreA: number;
  scoreB: number;
  players: number; // quantos jogaram
  craque: { name: string; rating: number | null }[];
  scorers: { name: string; goals: number }[];
  top: { pos: number; name: string; rating: number }[]; // vazio para quem não vê as notas
};

export function ResultArt({ data }: { data: ResultArtData }) {
  const post = useArtFormat() === 'post';
  const goals = data.scoreA + data.scoreB;
  const scorers = data.scorers.slice(0, post ? 3 : 5);
  return (
    <>
      <Header title={data.peladaName} subtitle={data.date} crestPath={data.crestPath} />
      <Score teamA={data.teamA} teamB={data.teamB} scoreA={data.scoreA} scoreB={data.scoreB} />
      <Text style={[s.muted, { textAlign: 'center' }]}>
        {data.players} jogadores · {goals === 0 ? 'sem gols' : `${goals} ${goals === 1 ? 'gol' : 'gols'}`}
      </Text>
      {data.craque.length > 0 && (
        <View style={[s.goldBox, post && { paddingVertical: 8 }]}>
          <Text style={s.goldLabel}>Craque da Partida</Text>
          {data.craque.map((c) => (
            <Text key={c.name} style={s.bigName} numberOfLines={1}>
              {c.name}
              {c.rating !== null ? `  ${fmtRating(c.rating)}` : ''}
            </Text>
          ))}
        </View>
      )}
      {scorers.length > 0 && (
        <Text style={s.center} numberOfLines={2}>
          Gols: {scorers.map((g) => (g.goals > 1 ? `${g.name} (${g.goals})` : g.name)).join(', ')}
          {data.scorers.length > scorers.length ? ' e outros' : ''}
        </Text>
      )}
      {/* Notas: top 3 nos Stories; no 4:5 a arte fica só com o resultado (não cabe com qualidade). */}
      {data.top.length > 0 && !post && (
        <View style={{ gap: 5 }}>
          <Text style={s.section}>Notas da rodada</Text>
          {data.top.slice(0, 3).map((t) => (
            <View key={`${t.pos}-${t.name}`} style={s.row}>
              <Text style={s.rowPos}>{t.pos}º</Text>
              <Text style={s.rowName} numberOfLines={1}>
                {t.name}
              </Text>
              <Text style={s.rowValue}>{fmtRating(t.rating)}</Text>
            </View>
          ))}
        </View>
      )}
    </>
  );
}

// ---------- Arte pós-jogo individual ----------
// O desempenho da pessoa NAQUELA partida (não é o Card). Só a própria pessoa gera a sua.
// Zero gols ou assistências aparecem como 0 (é o número oficial); nota só se oficial e visível.

export type PostGameArtData = {
  peladaName: string;
  crestPath?: string | null;
  date: string;
  playerName: string;
  photoPath: string | null | undefined;
  teamA: string;
  teamB: string;
  scoreA: number;
  scoreB: number;
  myTeam: 'A' | 'B';
  goals: number;
  assists: number;
  rating: number | null;
  craque: boolean;
};

export function PostGameArt({ data }: { data: PostGameArtData }) {
  const post = useArtFormat() === 'post';
  const mine = data.myTeam === 'A' ? data.scoreA : data.scoreB;
  const theirs = data.myTeam === 'A' ? data.scoreB : data.scoreA;
  const outcome = mine > theirs ? 'VITÓRIA' : mine < theirs ? 'DERROTA' : 'EMPATE';
  const stats = [
    { label: data.goals === 1 ? 'Gol' : 'Gols', value: String(data.goals) },
    { label: data.assists === 1 ? 'Assistência' : 'Assistências', value: String(data.assists) },
    ...(data.rating !== null ? [{ label: 'Nota', value: fmtRating(data.rating) }] : []),
  ];
  return (
    <>
      <Header title={data.peladaName} subtitle={data.date} crestPath={post ? undefined : data.crestPath} />
      {/* No 4:5 a foto fica ao lado do nome, para caber na altura menor. */}
      <View style={post ? { flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 12 } : { alignItems: 'center', gap: 8 }}>
        <View style={[s.photoRing, data.craque && { borderColor: colors.gold }]}>
          <Avatar path={data.photoPath} name={data.playerName} size={post ? 60 : 112} />
        </View>
        <View style={{ alignItems: post ? 'flex-start' : 'center', gap: 6, flexShrink: 1 }}>
          <Text style={s.bigName} numberOfLines={1}>
            {data.playerName}
          </Text>
          {data.craque && (
            <View style={s.badge}>
              <Text style={s.badgeText}>Craque da Partida</Text>
            </View>
          )}
        </View>
      </View>
      <View style={{ alignItems: 'center', gap: 2 }}>
        <Text style={[s.outcome, outcome === 'VITÓRIA' && { color: colors.blue }]}>{outcome}</Text>
        <Score teamA={data.teamA} teamB={data.teamB} scoreA={data.scoreA} scoreB={data.scoreB} />
      </View>
      <View style={s.statsRow}>
        {stats.map((x) => (
          <View key={x.label} style={[s.stat, post && { paddingVertical: 6 }]}>
            <Text style={s.statValue}>{x.value}</Text>
            <Text style={s.statLabel}>{x.label}</Text>
          </View>
        ))}
      </View>
    </>
  );
}

// ---------- Seleção da Rodada (4-3-3, sem adaptação: vaga sem candidato fica vazia) ----------

export type SelectionSlot = { position: string; name: string | null; rating: number | null; best: boolean };
export const FORMATION: { position: string; count: number }[] = [
  { position: 'attacker', count: 3 },
  { position: 'midfielder', count: 3 },
  { position: 'defender', count: 4 },
  { position: 'goalkeeper', count: 1 },
];

// V4.6: a peça da Seleção traz o nome da pelada, "Seleção da Rodada", a partida (data e times), o campo verde com
// fotos e bordas dos times, a legenda das cores e a assinatura 91’ (no canto do campo e no rodapé da arte).
export function SelectionArt({
  peladaName,
  crestPath,
  date,
  matchLabel,
  players,
  teams,
}: {
  peladaName: string;
  crestPath?: string | null;
  date: string;
  matchLabel: string;
  players: FieldPlayer[];
  teams: { name: string; color: string | null }[];
}) {
  const post = useArtFormat() === 'post';
  return (
    <>
      <Header title={peladaName} subtitle={`${matchLabel} · ${date}`} crestPath={post ? undefined : crestPath} />
      <Text style={[s.goldLabel, { textAlign: 'center', color: colors.blue, fontSize: 18 }]}>Seleção da Rodada</Text>
      <View style={{ alignItems: 'center' }}>
        <SelectionField players={players} width={post ? 144 : 220} />
      </View>
      {/* No 4:5 não sobra altura para a legenda (a cor continua na borda de cada jogador). */}
      {!post && <TeamLegend teams={teams} />}
    </>
  );
}

// ---------- Card do jogador (desenho em playercard.tsx) ----------

export { CARD_W, PlayerCard };

export function CardArt(props: {
  peladaName: string;
  crestPath?: string | null;
  seasonName: string;
  seasonStart?: string | null;
  playerName: string;
  photoPath: string | null | undefined;
  card: CardData;
  photoUrl?: string | null;
  crestUrl?: string | null;
}) {
  const post = useArtFormat() === 'post';
  return (
    <>
      {/* Centraliza o Card na altura da arte (o painel põe um espaço flexível antes da logo). */}
      <View style={{ flex: 1 }} />
      <Text style={[s.goldLabel, { textAlign: 'center', color: colors.blue }]}>Card da temporada</Text>
      <View style={{ alignItems: 'center' }}>
        <PlayerCard {...props} width={post ? 210 : CARD_W} />
      </View>
    </>
  );
}

// ---------- Figurinha conquistada ----------

// V4.6: a figurinha desenhada (ilustração da coleção e acabamento do nível), sem a estrela genérica.
export function StickerArt({
  peladaName,
  playerName,
  collection,
  art,
  sticker,
  level,
  criteria,
  date,
}: {
  peladaName: string;
  playerName: string;
  collection: string;
  art: StickerArtCode;
  sticker: string;
  level: number;
  criteria: string;
  date: string;
}) {
  const post = useArtFormat() === 'post';
  return (
    <>
      <Header title={peladaName} subtitle={playerName} />
      <Text style={[s.goldLabel, { textAlign: 'center' }]}>Figurinha conquistada</Text>
      <View style={{ alignItems: 'center', gap: post ? 4 : 8 }}>
        <StickerTile art={art} level={level} title={sticker} sub={collection} width={post ? 128 : 190} />
        <Text style={s.center} numberOfLines={post ? 2 : 3}>
          {criteria}
        </Text>
        <Text style={s.muted}>Conquistada em {date}</Text>
      </View>
    </>
  );
}

// ---------- Retrospectiva da temporada ----------
// Básica (grátis): capa da pelada e "minha temporada". Especial (Premium da pelada): os rankings da
// temporada. Bola Murcha nunca entra nas artes (não é conquista). Temporada em andamento = "parcial".

function RetroCover({ peladaName, crestPath, seasonName, partial }: { peladaName: string; crestPath?: string | null; seasonName: string; partial: boolean }) {
  return (
    <>
      <Header title={peladaName} subtitle={seasonName} crestPath={crestPath} />
      <Text style={[s.goldLabel, { textAlign: 'center', color: colors.blue }]}>
        RETROSPECTIVA{partial ? ' (PARCIAL)' : ''}
      </Text>
    </>
  );
}

function BigNumbers({ items }: { items: { label: string; value: string }[] }) {
  const post = useArtFormat() === 'post';
  return (
    <View style={s.statsRow}>
      {items.map((x) => (
        <View key={x.label} style={[s.stat, post && { paddingVertical: 6 }]}>
          <Text style={s.statValue}>{x.value}</Text>
          <Text style={s.statLabel}>{x.label}</Text>
        </View>
      ))}
    </View>
  );
}

export function RetroPeladaArt({
  peladaName,
  crestPath,
  seasonName,
  partial,
  retro,
}: {
  peladaName: string;
  crestPath?: string | null;
  seasonName: string;
  partial: boolean;
  retro: PeladaRetro;
}) {
  const post = useArtFormat() === 'post';
  const avg = retro.matches ? (retro.goals / retro.matches).toFixed(1).replace('.', ',') : '0';
  const lines = [
    retro.scorers[0] && { label: 'Artilheiro', text: `${retro.scorers[0].name} (${retro.scorers[0].value})` },
    retro.craques[0] && { label: 'Mais vezes Craque da Partida', text: `${retro.craques[0].name} (${retro.craques[0].value})` },
    retro.kings.length > 0 && { label: 'Reis do Mês', text: plural(retro.kings.length, 'mês', 'meses') + ' com Rei' },
    retro.biggestWin && {
      label: 'Maior placar',
      text: `${retro.biggestWin.team_a_name} ${retro.biggestWin.team_a_score} x ${retro.biggestWin.team_b_score} ${retro.biggestWin.team_b_name}`,
    },
  ]
    .filter(Boolean)
    .slice(0, post ? 3 : 4) as { label: string; text: string }[];
  return (
    <>
      <RetroCover peladaName={peladaName} crestPath={crestPath} seasonName={seasonName} partial={partial} />
      <BigNumbers
        items={[
          { label: 'Partidas', value: String(retro.matches) },
          { label: 'Gols', value: String(retro.goals) },
          { label: 'Gols/jogo', value: avg },
        ]}
      />
      <View style={{ gap: 8 }}>
        {lines.map((l) => (
          <View key={l.label} style={{ alignItems: 'center' }}>
            <Text style={s.section}>{l.label}</Text>
            <Text style={s.center} numberOfLines={2}>
              {l.text}
            </Text>
          </View>
        ))}
      </View>
    </>
  );
}

export function RetroRankingsArt({
  peladaName,
  crestPath,
  seasonName,
  partial,
  retro,
}: {
  peladaName: string;
  crestPath?: string | null;
  seasonName: string;
  partial: boolean;
  retro: PeladaRetro;
}) {
  const post = useArtFormat() === 'post';
  const blocks = [
    { title: 'Artilharia', rows: retro.scorers },
    { title: 'Garçons', rows: retro.assisters },
    { title: 'Craque da Partida', rows: retro.craques },
    { title: 'Mais presentes', rows: retro.presence },
  ].filter((b) => b.rows.length > 0);
  return (
    <>
      <RetroCover peladaName={peladaName} crestPath={post ? undefined : crestPath} seasonName={seasonName} partial={partial} />
      <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 10 }}>
        {blocks.map((b) => (
          <View key={b.title} style={{ width: '47%', gap: 2 }}>
            <Text style={s.section}>{b.title}</Text>
            {b.rows.slice(0, 3).map((r) => (
              <View key={r.membershipId} style={s.row}>
                <Text style={[s.rowName, { fontSize: 12 }]} numberOfLines={1}>
                  {r.rank}. {r.name}
                </Text>
                <Text style={[s.rowValue, { fontSize: 12 }]}>{r.value}</Text>
              </View>
            ))}
          </View>
        ))}
      </View>
    </>
  );
}

export function RetroPlayerArt({
  peladaName,
  crestPath,
  seasonName,
  partial,
  playerName,
  photoPath,
  me,
}: {
  peladaName: string;
  crestPath?: string | null;
  seasonName: string;
  partial: boolean;
  playerName: string;
  photoPath: string | null | undefined;
  me: PlayerRetro;
}) {
  const post = useArtFormat() === 'post';
  const honors = [
    me.craque > 0 && plural(me.craque, 'vez Craque da Partida', 'vezes Craque da Partida'),
    me.kings > 0 && plural(me.kings, 'vez Rei do Mês', 'vezes Rei do Mês'),
  ].filter(Boolean) as string[];
  return (
    <>
      <RetroCover peladaName={peladaName} crestPath={post ? undefined : crestPath} seasonName={seasonName} partial={partial} />
      <View style={post ? { flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 12 } : { alignItems: 'center', gap: 6 }}>
        <View style={[s.photoRing, honors.length > 0 && { borderColor: colors.gold }]}>
          <Avatar path={photoPath} name={playerName} size={post ? 56 : 96} />
        </View>
        <Text style={s.bigName} numberOfLines={1}>
          {playerName}
        </Text>
      </View>
      <BigNumbers
        items={[
          { label: me.matches === 1 ? 'Jogo' : 'Jogos', value: String(me.matches) },
          { label: me.goals === 1 ? 'Gol' : 'Gols', value: String(me.goals) },
          { label: me.assists === 1 ? 'Assist.' : 'Assists.', value: String(me.assists) },
        ]}
      />
      <Text style={[s.center, { color: colors.muted }]}>
        {plural(me.wins, 'vitória', 'vitórias')} · {plural(me.draws, 'empate', 'empates')} · {plural(me.losses, 'derrota', 'derrotas')}
      </Text>
      {honors.map((h) => (
        <View key={h} style={[s.badge, { alignSelf: 'center' }]}>
          <Text style={s.badgeText}>{h}</Text>
        </View>
      ))}
    </>
  );
}

const s = StyleSheet.create({
  frame: {
    width: W,
    backgroundColor: colors.white,
    paddingHorizontal: 20,
    borderWidth: 1,
    borderColor: colors.line,
  },
  logo: { textAlign: 'center', fontSize: 11, fontWeight: '800', letterSpacing: 3, color: colors.blue, opacity: 0.6 },
  pelada: { fontSize: 18, fontWeight: '800', color: colors.deepBlue },
  muted: { fontSize: 12, color: colors.muted },
  center: { fontSize: 13, fontWeight: '600', color: colors.ink, textAlign: 'center' },
  team: { fontSize: 13, fontWeight: '700', color: colors.ink, textAlign: 'center' },
  score: { fontSize: 36, fontWeight: '800', color: colors.blue },
  goldBox: { alignItems: 'center', gap: 4, paddingVertical: 12, borderRadius: 12, borderWidth: 2, borderColor: colors.gold },
  goldLabel: { fontSize: 14, fontWeight: '700', letterSpacing: 0.2, color: colors.darkGold },
  bigName: { fontSize: 20, fontWeight: '800', color: colors.deepBlue },
  section: { fontSize: 12, fontWeight: '800', color: colors.blue, marginBottom: 2 },
  row: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  rowPos: { width: 26, fontSize: 13, fontWeight: '700', color: colors.muted },
  rowName: { flex: 1, fontSize: 14, color: colors.ink },
  rowValue: { fontSize: 14, fontWeight: '800', color: colors.deepBlue },
  photoRing: { borderRadius: 999, borderWidth: 3, borderColor: colors.line, padding: 3 },
  badge: { borderRadius: 999, backgroundColor: colors.gold, paddingHorizontal: 12, paddingVertical: 4 },
  badgeText: { fontSize: 12, fontWeight: '700', letterSpacing: 0.2, color: colors.deepBlue },
  outcome: { fontSize: 13, fontWeight: '700', letterSpacing: 0.3, color: colors.muted },
  statsRow: { flexDirection: 'row', justifyContent: 'center', gap: 10 },
  stat: { flex: 1, alignItems: 'center', paddingVertical: 10, borderRadius: 12, backgroundColor: colors.bg },
  statValue: { fontSize: 26, fontWeight: '800', color: colors.deepBlue },
  statLabel: { fontSize: 11, fontWeight: '700', color: colors.muted },
  // Campo abstrato: linhas azul-claro, sem gramado (Brand Book 7.3).
  field: {
    height: 336, // cabe com o escudo no topo
    borderWidth: 2,
    borderColor: '#DCE7FA',
    borderRadius: 10,
    justifyContent: 'space-around',
    paddingVertical: 8,
  },
  midline: { position: 'absolute', left: 0, right: 0, top: '50%', height: 2, backgroundColor: '#DCE7FA' },
  circle: {
    position: 'absolute',
    left: '50%',
    top: '50%',
    width: 70,
    height: 70,
    marginLeft: -35,
    marginTop: -35,
    borderRadius: 35,
    borderWidth: 2,
    borderColor: '#DCE7FA',
  },
  fieldRow: { flexDirection: 'row', justifyContent: 'space-around' },
  player: { alignItems: 'center', width: 64, gap: 2 },
  marker: { width: 22, height: 22, borderRadius: 11, backgroundColor: colors.blue, borderWidth: 2, borderColor: colors.blue },
  playerName: { fontSize: 11, fontWeight: '700', color: colors.ink, maxWidth: 64 },
  playerRating: { fontSize: 11, fontWeight: '800', color: colors.deepBlue },
  sticker: { alignItems: 'center', gap: 10, paddingVertical: 18, borderRadius: 16, borderWidth: 2, borderColor: colors.gold },
  emblem: {
    width: 110,
    height: 110,
    borderRadius: 55,
    borderWidth: 3,
    borderColor: colors.gold,
    alignItems: 'center',
    justifyContent: 'center',
  },
  dot: { width: 10, height: 10, borderRadius: 5, borderWidth: 1, borderColor: colors.line },
});
