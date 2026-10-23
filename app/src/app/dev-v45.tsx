// Vitrine da V4.5: só em desenvolvimento (fora do __DEV__ não mostra nada). Exercita o usePaged de verdade (o mesmo
// das listas do Financeiro) contra um servidor FALSO com atraso aleatório: vários "Carregar mais" ao mesmo tempo,
// recarga no meio e troca de filtro. Mostra quantas requisições saíram e se apareceu item repetido ou fora de ordem.
// DADOS SIMULADOS; nunca lê o Supabase. Não é teste de integração (os testes automáticos estão em
// supabase/local_db/pager_logic.test.mjs).
import { useCallback, useState } from 'react';
import { View } from 'react-native';
import { Text } from '../lib/text';

import { Page, usePaged } from '../lib/paging';
import { colors } from '../lib/theme';
import { Body, Button, Card, Chips, ListScreen, Sub, Title } from '../lib/ui';

type Row = { id: string; n: number };
const TOTAL = 95;
const SIZE = 10;

export default function DevV45() {
  const [filter, setFilter] = useState<'A' | 'B'>('A');
  const [calls, setCalls] = useState(0);
  const [log, setLog] = useState<string[]>([]);
  const fetchPage = useCallback(
    async (after: number | null): Promise<Page<Row, number>> => {
      setCalls((c) => c + 1);
      const start = after ?? 0;
      const wait = 80 + Math.floor(Math.random() * 500);
      await new Promise((r) => setTimeout(r, wait));
      const items: Row[] = [];
      for (let i = start + 1; i <= Math.min(TOTAL, start + SIZE); i++) items.push({ id: `${filter}${i}`, n: i });
      setLog((l) => [`${filter} depois de ${after ?? 'início'}: ${items.length} itens em ${wait} ms`, ...l].slice(0, 6));
      return { items, next: start + SIZE < TOTAL ? start + SIZE : null };
    },
    [filter],
  );
  const list = usePaged(fetchPage, (x) => x.id);
  if (!__DEV__) return null;

  const items = list.items ?? [];
  const dups = items.length - new Set(items.map((x) => x.id)).size;
  const outOfOrder = items.filter((x, i) => i > 0 && x.n <= items[i - 1].n).length;
  const wrongFilter = items.filter((x) => !x.id.startsWith(filter)).length;
  const ok = dups === 0 && outOfOrder === 0 && wrongFilter === 0;

  const header = (
    <>
      <Title>Vitrine V4.5</Title>
      <Sub>DADOS SIMULADOS (servidor falso com atraso aleatório). Não é teste de integração.</Sub>
      <Chips
        options={[
          { value: 'A', label: 'Filtro A' },
          { value: 'B', label: 'Filtro B' },
        ]}
        value={filter}
        onChange={(v) => setFilter(v as 'A' | 'B')}
      />
      <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 8 }}>
        <View style={{ flex: 1, minWidth: 150 }}>
          <Button
            title="Carregar mais ×3 juntos"
            kind="secondary"
            onPress={() => {
              list.loadMore();
              list.loadMore();
              list.loadMore();
            }}
          />
        </View>
        <View style={{ flex: 1, minWidth: 150 }}>
          <Button
            title="Mais + recarregar no meio"
            kind="secondary"
            onPress={() => {
              list.loadMore();
              setTimeout(list.refresh, 40);
            }}
          />
        </View>
      </View>
      <Card>
        <Body>
          {items.length} itens · {calls} requisições · {list.loading ? 'recarregando' : list.loadingMore ? 'carregando mais' : 'parado'}
        </Body>
        <Text style={{ color: ok ? colors.blue : colors.danger, fontWeight: '800' }} accessibilityLiveRegion="polite">
          {ok ? 'Sem repetição, em ordem e só do filtro atual' : `Problema: ${dups} repetidos, ${outOfOrder} fora de ordem, ${wrongFilter} de outro filtro`}
        </Text>
        {log.map((l, i) => (
          <Sub key={i}>{l}</Sub>
        ))}
      </Card>
    </>
  );
  return (
    <ListScreen
      header={header}
      data={list.items}
      keyExtractor={(r) => r.id}
      loadingMore={list.loadingMore}
      onEndReached={list.loadMore}
      footer={list.hasMore && !list.loadingMore ? <Button title="Carregar mais" kind="secondary" onPress={list.loadMore} /> : null}
      renderItem={(r) => (
        <Card>
          <Body>
            Item {r.id} (posição {r.n})
          </Body>
        </Card>
      )}
    />
  );
}
