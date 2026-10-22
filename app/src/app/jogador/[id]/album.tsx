import { useLocalSearchParams } from 'expo-router';
import { useEffect, useState } from 'react';
import { Text, View } from 'react-native';

import { SharePanel, StickerArt } from '../../../lib/arts';
import { friendly } from '../../../lib/errors';
import { useAuth } from '../../../lib/session';
import { supabase } from '../../../lib/supabase';
import { colors } from '../../../lib/theme';
import { Body, Card, ErrorText, Screen, Sub, Title } from '../../../lib/ui';

type Collection = { id: string; name: string; display_order: number };
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
  const [msg, setMsg] = useState<string | null>(null);

  useEffect(() => {
    (async () => {
      const [{ data: m }, { data: cs }, { data: ds }, { data: ps }, { data: us }] = await Promise.all([
        supabase.from('pelada_memberships').select('player_name, user_id, pelada_id').eq('id', id).maybeSingle(),
        supabase.from('sticker_collections').select('id, name, display_order').eq('is_active', true).order('display_order'),
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
        {!msg && <Sub>Carregando...</Sub>}
      </Screen>
    );
  }

  return (
    <Screen>
      <Title>Álbum{name ? ` de ${name}` : ''}</Title>
      <Sub>
        {unlocked.size} de {stickers.length} figurinhas. Elas são conquistadas jogando, nunca compradas.
      </Sub>
      {collections.map((c) => {
        const items = stickers.filter((s) => s.collection_id === c.id);
        const done = items.filter((s) => unlocked.has(s.id)).length;
        return (
          <Card key={c.id}>
            <Body>
              {c.name} · {done}/{items.length}
            </Body>
            {items.map((s) => {
              const at = unlocked.get(s.id);
              const current = Math.min(progress.get(s.id) ?? 0, s.threshold);
              return (
                <View key={s.id} style={{ gap: 4, paddingVertical: 6, opacity: at ? 1 : 0.6 }}>
                  <View style={{ flexDirection: 'row', justifyContent: 'space-between' }}>
                    <Text style={{ color: at ? colors.darkGold : colors.ink, fontWeight: '700' }}>
                      {at ? '★ ' : ''}
                      {s.name}
                    </Text>
                    <Text style={{ color: colors.muted, fontSize: 13 }}>
                      {at ? `Conquistada em ${new Date(at).toLocaleDateString('pt-BR')}` : 'Bloqueada'}
                    </Text>
                  </View>
                  <Sub>
                    {(CRITERIA[s.metric_code] ?? String)(s.threshold)} · {current}/{s.threshold}
                  </Sub>
                  <View style={{ height: 6, borderRadius: 3, backgroundColor: colors.line }}>
                    <View
                      style={{
                        height: 6,
                        borderRadius: 3,
                        width: `${(current / s.threshold) * 100}%`,
                        backgroundColor: at ? colors.gold : colors.blue,
                      }}
                    />
                  </View>
                  {/* Só as próprias figurinhas conquistadas (Doc 03 22.7). */}
                  {at && isMe && (
                    <SharePanel label="Compartilhar figurinha" fileName="minuto91-figurinha" title={s.name}>
                      <StickerArt
                        peladaName={peladaName}
                        playerName={name}
                        collection={c.name}
                        sticker={s.name}
                        level={s.level}
                        criteria={(CRITERIA[s.metric_code] ?? String)(s.threshold)}
                        date={new Date(at).toLocaleDateString('pt-BR')}
                      />
                    </SharePanel>
                  )}
                </View>
              );
            })}
          </Card>
        );
      })}
    </Screen>
  );
}
