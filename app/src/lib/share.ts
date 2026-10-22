// Compartilhar uma View como imagem PNG. No celular abre a folha de compartilhamento (WhatsApp etc.);
// na web usa o compartilhamento do navegador quando existe, senão baixa o arquivo.
import * as Sharing from 'expo-sharing';
import type { RefObject } from 'react';
import { PixelRatio, Platform, View } from 'react-native';
import { captureRef } from 'react-native-view-shot';

export async function shareViewAsImage(ref: RefObject<View | null>, fileName: string, title: string) {
  if (Platform.OS === 'web') {
    // 1080 x 1920 (9:16), qualquer que seja a tela.
    const dataUri = await captureRef(ref, { format: 'png', result: 'data-uri', width: 1080, height: 1920 });
    const blob = await (await fetch(dataUri)).blob();
    const file = new File([blob], `${fileName}.png`, { type: 'image/png' });
    if (navigator.canShare?.({ files: [file] })) {
      await navigator.share({ files: [file], title });
      return;
    }
    const a = document.createElement('a');
    a.href = dataUri;
    a.download = `${fileName}.png`;
    a.click();
    return;
  }
  // No celular width/height são divididos pela densidade da tela para sair em 1080 x 1920.
  const ratio = PixelRatio.get();
  const uri = await captureRef(ref, { format: 'png', result: 'tmpfile', fileName, width: 1080 / ratio, height: 1920 / ratio });
  if (!(await Sharing.isAvailableAsync())) throw new Error('Compartilhamento indisponível neste aparelho.');
  await Sharing.shareAsync(uri, { mimeType: 'image/png', UTI: 'public.png', dialogTitle: title });
}
