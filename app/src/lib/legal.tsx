// A18: Termos de Uso e Política de Privacidade oficiais, legíveis antes do aceite (sem login). O texto vem
// sem edição de legalText.ts; o aceite grava documento + versão + momento (migração 037).
import { Text } from './text';

import { LEGAL_VERSIONS, PRIVACY, TERMS } from './legalText';
import { colors } from './theme';
import { Screen, Sub } from './ui';

// Linha que começa com "1." ou "12.3." vira título de seção ou cláusula; o resto é parágrafo.
const isHeading = (l: string) => /^\d+\.\s+\S/.test(l) && l.length < 90 && !/^\d+\.\d/.test(l);

export function LegalDocument({ doc }: { doc: 'terms' | 'privacy' }) {
  const lines = doc === 'terms' ? TERMS : PRIVACY;
  const version = doc === 'terms' ? LEGAL_VERSIONS.terms : LEGAL_VERSIONS.privacy;
  return (
    <Screen>
      <Sub>Versão {version}. Texto oficial do Minuto 91.</Sub>
      {lines.map((l, i) => (
        <Text
          key={i}
          style={
            isHeading(l)
              ? { fontSize: 17, fontWeight: '800', color: colors.ink, marginTop: 10 }
              : { fontSize: 15, lineHeight: 22, color: colors.ink }
          }>
          {l}
        </Text>
      ))}
    </Screen>
  );
}
