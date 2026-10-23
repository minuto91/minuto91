// Escudo da pelada (migração 028): bucket privado "crests", arquivo <id da pelada>/<uuid>.png|.jpg.
// Só o admin envia, troca ou remove. O escudo pode ter qualquer formato (redondo, triangular,
// irregular): nada é recortado; a imagem só é reduzida (lado maior até 512 px) mantendo a proporção.
// Imagem com transparência (PNG, WEBP) sai sempre em PNG, que mantém o canal alfa; nunca vira JPEG.
// Só uma foto sem transparência (JPG, HEIC) pode sair em JPEG. Antes de salvar, o admin vê o escudo
// sobre os Cards bronze, prata e ouro e no cabeçalho (pickCrest → prévia → uploadCrest).
// Exibido só por URL temporária assinada; sem escudo, o escudo padrão com as iniciais da pelada.
import { Image } from 'expo-image';
import { useArtImage } from './artload';
import { ImageManipulator, SaveFormat } from 'expo-image-manipulator';
import * as ImagePicker from 'expo-image-picker';
import { useState } from 'react';
import { Platform, View } from 'react-native';
import { Text } from './text';

import { useSignedUrl, uuid } from './avatar';
import { friendly } from './errors';
import { supabase } from './supabase';
import { colors } from './theme';

const BUCKET = 'crests';
const SIDES = [512, 384, 256]; // lado maior do arquivo final; tenta menores se passar de 1 MB
const MIN_SIDE = 128; // menor que isso fica borrado
const MAX_PICK_BYTES = 20 * 1024 * 1024; // antes de reduzir
const MAX_UPLOAD_BYTES = 1024 * 1024; // limite do bucket
const CACHE_SECONDS = '300'; // cache da CDN: escudo trocado ou removido some em até 5 min

async function removeFile(path: string | null) {
  if (path) await supabase.storage.from(BUCKET).remove([path]); // melhor esforço; o resto a limpeza apaga
}

/** Escudo preparado, ainda não enviado. transparent: null quando não dá para saber (PNG no celular). */
export type CrestDraft = { uri: string; body: ArrayBuffer; ext: 'png' | 'jpg'; transparent: boolean | null };

// Na web, confere se algum pixel tem transparência (amostra de até 128 x 128).
async function webHasAlpha(uri: string): Promise<boolean | null> {
  if (Platform.OS !== 'web' || typeof document === 'undefined') return null;
  try {
    const img = new window.Image();
    img.crossOrigin = 'anonymous';
    await new Promise<void>((ok, fail) => {
      img.onload = () => ok();
      img.onerror = () => fail(new Error('load'));
      img.src = uri;
    });
    const k = Math.min(1, 128 / Math.max(img.width, img.height));
    const w = Math.max(1, Math.round(img.width * k));
    const h = Math.max(1, Math.round(img.height * k));
    const canvas = document.createElement('canvas');
    canvas.width = w;
    canvas.height = h;
    const ctx = canvas.getContext('2d');
    if (!ctx) return null;
    ctx.drawImage(img, 0, 0, w, h);
    const px = ctx.getImageData(0, 0, w, h).data;
    for (let i = 3; i < px.length; i += 4) if (px[i] < 250) return true;
    return false;
  } catch {
    return null;
  }
}

/** Abre a galeria e prepara o escudo (sem enviar). null se o admin desistiu. */
export async function pickCrest(): Promise<CrestDraft | null> {
  // Sem editor de recorte: o editor do sistema só recorta quadrado e cortaria o escudo.
  const picked = await ImagePicker.launchImageLibraryAsync({ mediaTypes: ['images'], allowsEditing: false, quality: 1 });
  if (picked.canceled || !picked.assets?.length) return null;
  const a = picked.assets[0];
  const mime = a.mimeType ?? '';
  if (mime && !/^image\/(jpeg|png|heic|heif|webp)$/.test(mime)) throw new Error('Use uma imagem PNG, WEBP, JPG ou HEIC.');
  if (a.fileSize && a.fileSize > MAX_PICK_BYTES) throw new Error('Imagem muito grande (máximo 20 MB).');
  if (Math.max(a.width, a.height) < MIN_SIDE) throw new Error(`Imagem muito pequena (mínimo ${MIN_SIDE} px no lado maior).`);

  // JPG e HEIC não têm transparência; PNG e WEBP podem ter.
  const opaqueSource = /^image\/(jpeg|heic|heif)$/.test(mime);
  for (const side of SIDES) {
    const ctx = ImageManipulator.manipulate(a.uri);
    if (Math.max(a.width, a.height) > side) ctx.resize(a.width >= a.height ? { width: side } : { height: side });
    const rendered = await ctx.renderAsync();
    const saved = await rendered.saveAsync(opaqueSource ? { compress: 0.9, format: SaveFormat.JPEG } : { format: SaveFormat.PNG });
    const body = await (await fetch(saved.uri)).arrayBuffer();
    if (body.byteLength <= MAX_UPLOAD_BYTES) {
      const transparent = opaqueSource ? false : await webHasAlpha(saved.uri);
      return { uri: saved.uri, body, ext: opaqueSource ? 'jpg' : 'png', transparent };
    }
  }
  throw new Error('Não foi possível reduzir o escudo para 1 MB. Tente outra imagem.');
}

/** Envia o escudo já conferido na prévia. Devolve o novo caminho. */
export async function uploadCrest(peladaId: string, draft: CrestDraft): Promise<string> {
  const path = `${peladaId}/${uuid()}.${draft.ext}`;
  const up = await supabase.storage.from(BUCKET).upload(path, draft.body, {
    contentType: draft.ext === 'png' ? 'image/png' : 'image/jpeg',
    upsert: false,
    cacheControl: CACHE_SECONDS,
  });
  if (up.error) throw new Error('Não foi possível enviar o escudo. Verifique a internet e tente de novo.');
  const { data: old, error } = await supabase.rpc('set_pelada_crest', { p_pelada: peladaId, p_path: path });
  if (error) {
    await removeFile(path);
    throw new Error(friendly(error.message));
  }
  await removeFile(old as string | null);
  return path;
}
export async function removeCrest(peladaId: string) {
  const { data: old, error } = await supabase.rpc('clear_pelada_crest', { p_pelada: peladaId });
  if (error) throw new Error(friendly(error.message));
  await removeFile(old as string | null);
}

export const useCrestUrl = (path: string | null | undefined) => useSignedUrl(BUCKET, path);

const SMALL_WORDS = new Set(['de', 'do', 'da', 'dos', 'das', 'e', 'fc', 'f.c.']);

/** Iniciais da pelada para o escudo padrão ("Pelada do Zé" → "PZ"). */
export const crestInitials = (name: string) => {
  const words = name.trim().split(/\s+/).filter((w) => w && !SMALL_WORDS.has(w.toLowerCase()));
  return (words.length ? words : name.trim().split(/\s+/))
    .slice(0, 2)
    .map((w) => w[0]?.toUpperCase() ?? '')
    .join('') || 'M';
};

/** Imagem do escudo já resolvida (para quem precisa da URL, como a arte exportada). */
export function CrestView({ url, name, size }: { url: string | null; name: string; size: number }) {
  const [loaded, setLoaded] = useState<{ url: string; aspect: number } | null>(null);
  const art = useArtImage(url); // A25: a arte espera o escudo
  // Forma de escudo simples: topo quase reto, base arredondada.
  const shape = {
    width: size,
    height: size,
    borderTopLeftRadius: size * 0.16,
    borderTopRightRadius: size * 0.16,
    borderBottomLeftRadius: size * 0.5,
    borderBottomRightRadius: size * 0.5,
  };
  if (url) {
    // Proporção calculada à mão (a captura da web ignora "contain" e esticaria o escudo).
    const aspect = loaded?.url === url ? loaded.aspect : 1;
    const w = aspect >= 1 ? size : size * aspect;
    const h = aspect >= 1 ? size / aspect : size;
    return (
      <View style={{ width: size, height: size, alignItems: 'center', justifyContent: 'center' }}>
        <Image
          source={{ uri: url }}
          style={{ width: w, height: h }}
          contentFit="contain"
          onLoad={(e) => {
            art.done();
            if (e.source.width > 0 && e.source.height > 0) setLoaded({ url, aspect: e.source.width / e.source.height });
          }}
          onError={art.done}
          accessibilityLabel={`Escudo de ${name}`}
        />
      </View>
    );
  }
  return (
    <View
      accessibilityLabel={`Escudo de ${name}`}
      style={[shape, { backgroundColor: colors.deepBlue, borderWidth: Math.max(1, size * 0.06), borderColor: colors.gold, alignItems: 'center', justifyContent: 'center' }]}>
      <Text style={{ color: colors.white, fontWeight: '800', fontSize: size * 0.34, marginTop: -size * 0.06 }}>{crestInitials(name)}</Text>
    </View>
  );
}

/** Escudo da pelada; sem imagem (ou carregando), o escudo padrão com as iniciais. */
export function Crest({ path, name, size = 40 }: { path: string | null | undefined; name: string; size?: number }) {
  return <CrestView url={useCrestUrl(path)} name={name} size={size} />;
}
