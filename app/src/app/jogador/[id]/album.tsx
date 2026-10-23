import { useLocalSearchParams } from 'expo-router';
import { useEffect, useState } from 'react';
import { Pressable, ScrollView, View } from 'react-native';

import { SharePanel, StickerArt } from '../../../lib/arts';
import { friendly } from '../../../lib/errors';
import { useAuth } from '../../../lib/session';
import { FINISH, finishOf, StickerArtCode, StickerTile } from '../../../lib/stickers';
import { supabase } from '../../../lib/supabase';
import { Text } from '../../../lib/text';
import { colors, type } from '../../../lib/theme';
import { Card, ErrorText, Loading, Screen, Sub, Title } from '../../../lib/ui';

type Collection = { id: string; code: StickerArtCode; name: string; display_order: number };
type Sticker = {
  id: string;
  collection_id: string;
  name: string;
  level: number;
  metric_code: string;
  threshold: number;
  display_order: number;
};

const CRITERIA: Record<string, (n: number) => string> = {
  mvp_count: (n) => `${n} ${n === 1 ? 'título' : 'títulos'} de Craque`,
  goals: (n) => `${n} ${n === 1 ? 'gol' : 'gols'}`,
  assists: (n) => `${n} ${n === 1 ? 'assistência' : 'assistências'}`,
  matches_played: (n) => `${n} ${n === 1 ? 'partida' : 'partidas'}`,
  best_win_streak: (n) => `${n} vitórias seguidas`,
  best_unbeaten_streak: (n) => `${n} partidas sem perder`,
  high_ratings: (n) => `${n} ${n === 1 ? 'partida' : 'partidas'} com nota 8+`,
  monthly_king_count: (n) => `${n} ${n === 1 ? 'título' : 'títulos'} de Rei do Mês`,
  selection_count: (n) => `${n} ${n === 1 ? 'convocação' : 'convocações'}`,
};
const criteria = (s: Sticker) => (CRITERIA[s.metric_code] ?? String)(s.threshold);

// V4.6: álbum organizado por coleção (nove faixas com os níveis reais de cada uma), progresso geral no topo, figurinhas
// bloqueadas com o requisito oficial e o progresso individual, e o detalhe ampliado ao tocar. As 48 figurinhas e os
// critérios vêm do catálogo do banco (017/018): nada é contado de novo aqui.
export default function Album() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const { session } = useAuth();
  const [name, setName] = useState('');
  const [isMe, setIsMe] = useState(false);
  const [peladaName, setPeladaName] = useState('');
  const [collections, setCollections] = useState<Collection[] | null>(null);
  const [stickers, setStickers] = useState<Sticker[]>([]);
  const [progress, setProgress] = useState<Map<string, number>>(new Map());
  const [unlocked, setUnlocked] = useState<Map<string, string>>(new Map());
  const [open, setOpen] = useState<string | null>(null);
  const [msg, setMsg] = useState<string | null>(null);

  useEffect(() => {
    (async () => {
      const [{ data: m }, { data: cs }, { data: ds }, { data: ps }, { data: us }] = await Promise.all([
        supabase.from('pelada_memberships').select('player_name, user_id, pelada_id').eq('id', id).maybeSingle(),
        supabase.from('sticker_collections').select('id, code, name, display_order').eq('is_active', true).order('display_order'),
        supabase
          .from('sticker_definitions')
          .select('id, collection_id, name, level, metric_code, threshold, display_order')
          .eq('is_active', true)
          .order('display_order'),
        supabase.from('player_sticker_progress').select('sticker_definition_id, current_value').eq('membership_id', id),
        supabase
          .from('player_sticker_unlocks')
          .select('sticker_definition_id, unlocked_at')
          .eq('membership_id', id)
          .eq('status', 'active'),
      ]);
      setName(m?.player_name ?? '');
      setIsMe(!!m?.user_id && m.user_id === session?.user.id);
      if (m) {
        const { data: p } = await supabase.from('peladas').select('name').eq('id', m.pelada_id).maybeSingle();
        setPeladaName(p?.name ?? '');
      }
      setCollections((cs ?? []) as Collection[]);
      setStickers((ds ?? []) as Sticker[]);
      setProgress(new Map((ps ?? []).map((p) => [p.sticker_definition_id, p.current_value])));
      setUnlocked(new Map((us ?? []).map((u) => [u.sticker_definition_id, u.unlocked_at])));
    })().catch((e) => setMsg(friendly((e as Error).message)));
  }, [id, session?.user.id]);

  if (!collections) {
    return (
      <Screen>
        <ErrorText>{msg}</ErrorText>
        {!msg && <Loading />}
      </Screen>
    );
  }

  const total = stickers.length;
  const done = stickers.filter((s) => unlocked.has(s.id)).length;
  const sel = stickers.find((s) => s.id === open) ?? null;
  const selCol = sel ? collections.find((c) => c.id === sel.collection_id) : null;

  return (
    <Screen>
      <Title>Álbum{name ? ` de ${name}` : ''}</Title>
      <View style={{ gap: 8 }}>
        <View style={{ flexDirection: 'row', alignItems: 'baseline', gap: 6 }}>
          <Text style={type.number}>{done}</Text>
          <Text style={type.caption}>de {total} figurinhas conquistadas</Text>
        </View>
        <View style={{ height: 8, borderRadius: 4, backgroundColor: '#E6EBF3', overflow: 'hidden' }} accessibilityLabel={`${done} de ${total}`}>
          <View style={{ height: 8, width: `${total ? (done / total) * 100 : 0}%`, backgroundColor: colors.blue }} />
        </View>
        <Sub>Conquistadas jogando, nunca compradas. Toque numa figurinha para ver o requisito.</Sub>
      </View>

      {sel && selCol && (
        <Card>
          <View style={{ alignItems: 'center', gap: 10 }}>
            <StickerTile art={selCol.code} level={sel.level} title={sel.name} sub={criteria(sel)} locked={!unlocked.has(sel.id)} width={180} />
            <Text style={type.cardTitle}>{sel.name}</Text>
            <Sub>
              {selCol.name} · nível {sel.level === 6 ? 'Lendário' : ['I', 'II', 'III', 'IV', 'V'][sel.level - 1]} · acabamento {FINISH[finishOf(sel.level)].label}
            </Sub>
            <Text style={type.body}>Requisito: {criteria(sel)}</Text>
            {(() => {
              const at = unlocked.get(sel.id);
              const cur = Math.min(progress.get(sel.id) ?? 0, sel.threshold);
              return at ? (
                <Text style={{ color: colors.darkGold, fontWeight: '600' }}>Conquistada em {new Date(at).toLocaleDateString('pt-BR')}</Text>
              ) : (
                <View style={{ alignSelf: 'stretch', gap: 4 }}>
                  <Sub>
                    Progresso: {cur} de {sel.threshold}
                  </Sub>
                  <View style={{ height: 6, borderRadius: 3, backgroundColor: colors.line }}>
                    <View style={{ height: 6, borderRadius: 3, width: `${(cur / sel.threshold) * 100}%`, backgroundColor: colors.blue }} />
                  </View>
                </View>
              );
            })()}
          </View>
          {/* Só as próprias figurinhas conquistadas (Doc 03 22.7). */}
          {unlocked.get(sel.id) && isMe && (
            <SharePanel label="Compartilhar figurinha" fileName="minuto91-figurinha" title={sel.name}>
              <StickerArt
                peladaName={peladaName}
                playerName={name}
                collection={selCol.name}
                art={selCol.code}
                sticker={sel.name}
                level={sel.level}
                criteria={criteria(sel)}
                date={new Date(unlocked.get(sel.id)!).toLocaleDateString('pt-BR')}
              />
            </SharePanel>
          )}
          <Pressable accessibilityRole="button" onPress={() => setOpen(null)} style={{ minHeight: 44, alignItems: 'center', justifyContent: 'center' }}>
            <Text style={{ color: colors.blue, fontWeight: '600' }}>Fechar</Text>
          </Pressable>
        </Card>
      )}

      {collections.map((c) => {
        const items = stickers.filter((s) => s.collection_id === c.id).sort((a, b) => a.level - b.level);
        const got = items.filter((s) => unlocked.has(s.id)).length;
        return (
          <View key={c.id} style={{ gap: 8, marginTop: 6 }}>
            <View style={{ flexDirection: 'row', alignItems: 'baseline', justifyContent: 'space-between' }}>
              <Text style={type.section}>{c.name}</Text>
              <Text style={type.meta}>
                {got} de {items.length}
              </Text>
            </View>
            <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={{ gap: 10, paddingRight: 8 }}>
              {items.map((s) => {
                const at = unlocked.get(s.id);
                const cur = Math.min(progress.get(s.id) ?? 0, s.threshold);
                return (
                  <Pressable
                    key={s.id}
                    accessibilityRole="button"
                    accessibilityLabel={`${s.name}, ${at ? 'conquistada' : `bloqueada, ${cur} de ${s.threshold}`}`}
                    accessibilityState={{ selected: open === s.id }}
                    onPress={() => setOpen(open === s.id ? null : s.id)}
                    style={{ alignItems: 'center', gap: 4, width: 96 }}>
                    <StickerTile art={c.code} level={s.level} title={s.name} locked={!at} width={96} />
                    <Text style={{ fontSize: 12, color: at ? colors.darkGold : colors.muted, fontWeight: '600', textAlign: 'center' }} numberOfLines={2}>
                      {at ? 'Conquistada' : `${cur}/${s.threshold}`}
                    </Text>
                  </Pressable>
                );
              })}
            </ScrollView>
          </View>
        );
      })}
    </Screen>
  );
}
