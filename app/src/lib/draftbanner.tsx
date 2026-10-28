import { View } from 'react-native';

import { colors, radius, type } from './theme';
import { Text } from './text';
import { Button } from './ui';

/** REV-044: rascunho encontrado; a pessoa decide. */
export function DraftBanner({ onResume, onDiscard }: { onResume: () => void; onDiscard: () => void }) {
  return (
    <View style={{ borderWidth: 1, borderColor: colors.line, borderRadius: radius.card, padding: 14, gap: 10 }}>
      <Text style={type.body}>Há um rascunho salvo neste aparelho.</Text>
      <View style={{ flexDirection: 'row', gap: 8 }}>
        <View style={{ flex: 1 }}>
          <Button title="Continuar" onPress={onResume} />
        </View>
        <View style={{ flex: 1 }}>
          <Button title="Descartar rascunho" kind="secondary" onPress={onDiscard} />
        </View>
      </View>
    </View>
  );
}
