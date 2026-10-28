import { useEffect, useState } from 'react';
import { View } from 'react-native';

import { friendly } from '../lib/errors';
import { supabase } from '../lib/supabase';
import { Text } from '../lib/text';
import { colors, radius, type } from '../lib/theme';
import { Button, EmptyState, ErrorText, Screen, Section, Sub, Title } from '../lib/ui';
import { Skeleton } from '../lib/central';

// REV-002: um único álbum por pessoa, somando as peladas (atuais e encerradas). Desbloqueio e bloqueio vêm do servidor.
type Sticker = { id: string; collection_id: string; name: string; level: number; threshold: number; value: number; unlocked_at: string | null };
type Album = { collections: { id: string; code: string; name: string }[]; stickers: Sticker[] };

export default function AlbumGlobal() {
  const [album, setAlbum] = useState<Album | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [retry, setRetry] = useState(0);

  useEffect(() => {
    supabase.rpc('get_my_global_album').then(({ data, error }) => {
      if (error) return setMsg(friendly(error.message));
      setMsg(null);
      setAlbum(data as Album);
    });
  }, [retry]);

  if (msg)
    return (
      <Screen>
        <ErrorText>{msg}</ErrorText>
        <Button title="Tentar de novo" kind="secondary" onPress={() => setRetry((n) => n + 1)} />
      </Screen>
    );
  if (!album)
    return (
      <Screen>
        <Skeleton height={32} />
        <Skeleton height={120} />
        <Skeleton height={120} />
      </Screen>
    );

  const total = album.stickers.length;
  const done = album.stickers.filter((s) => s.unlocked_at).length;
  if (total === 0) return <Screen><EmptyState title="Álbum vazio" /></Screen>;

  return (
    <Screen>
      <Title>Meu álbum</Title>
      <Sub>{`${done} de ${total}`}</Sub>
      <View style={{ height: 6, borderRadius: 3, backgroundColor: colors.line }}>
        <View style={{ width: `${(done / total) * 100}%`, height: 6, borderRadius: 3, backgroundColor: colors.gold }} />
      </View>
      {album.collections.map((c) => {
        const list = album.stickers.filter((s) => s.collection_id === c.id);
        return (
          <View key={c.id} style={{ gap: 8 }}>
            <Section>{c.name}</Section>
            <View style={{ flexDirection: 'row', flexWrap: 'wrap', marginHorizontal: -4 }}>
              {list.map((s) => {
                const on = !!s.unlocked_at;
                return (
                  <View key={s.id} style={{ width: '33.33%', padding: 4 }}>
                    <View
                      accessible
                      accessibilityLabel={`${s.name}: ${on ? 'conquistada' : `${Math.min(s.value, s.threshold)} de ${s.threshold}`}`}
                      style={{
                        aspectRatio: 0.78, borderRadius: radius.md, padding: 8, justifyContent: 'space-between',
                        borderWidth: on ? 2 : 1, borderColor: on ? colors.gold : colors.line,
                        backgroundColor: on ? colors.white : colors.bg,
                      }}>
                      <Text style={{ fontSize: 22, fontWeight: '900', color: on ? colors.blue : colors.line }}>{s.threshold}</Text>
                      <Text style={{ fontSize: 12, fontWeight: '700', color: on ? colors.ink : colors.muted }} numberOfLines={2}>{s.name}</Text>
                      {!on && <Text style={type.meta}>{`${Math.min(s.value, s.threshold)}/${s.threshold}`}</Text>}
                    </View>
                  </View>
                );
              })}
            </View>
          </View>
        );
      })}
    </Screen>
  );
}
