import { ReactNode, useState } from 'react';
import { Pressable, View } from 'react-native';

import { Icon } from './icons';
import { Text } from './text';
import { colors, type } from './theme';

/** Seção recolhível (linha inteira tocável, 48 pt). O conteúdo só é montado quando aberto. */
export function Collapsible({ title, children, initiallyOpen = false, right }: { title: string; children: ReactNode; initiallyOpen?: boolean; right?: string }) {
  const [open, setOpen] = useState(initiallyOpen);
  return (
    <View style={{ borderTopWidth: 1, borderTopColor: colors.line }}>
      <Pressable
        onPress={() => setOpen((o) => !o)}
        accessibilityRole="button"
        accessibilityState={{ expanded: open }}
        accessibilityLabel={title}
        style={{ minHeight: 48, flexDirection: 'row', alignItems: 'center', gap: 8 }}>
        <Text style={[type.cardTitle, { flex: 1 }]}>{title}</Text>
        {right ? <Text style={type.caption}>{right}</Text> : null}
        <View style={{ transform: [{ rotate: open ? '90deg' : '0deg' }] }}>
          <Icon name="chevron" size={18} color={colors.muted} />
        </View>
      </Pressable>
      {open && <View style={{ gap: 12, paddingBottom: 12 }}>{children}</View>}
    </View>
  );
}
