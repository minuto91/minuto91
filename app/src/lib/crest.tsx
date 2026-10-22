// Escudo da pelada (migração 028): bucket privado "crests", arquivo <id da pelada>/<uuid>.png|.jpg.
// Só o admin envia, troca ou remove. O escudo é recortado quadrado, reduzido para 512 px (PNG, que
// mantém o fundo transparente; JPEG se o PNG passar de 1 MB) e exibido só por URL temporária assinada.
// Sem escudo, mostra um escudo padrão com as iniciais da pelada.
import { Image } from 'expo-image';
import { ImageManipulator, SaveFormat } from 'expo-image-manipulator';
import * as ImagePicker from 'expo-image-picker';
import { Text, View } from 'react-native';

import { useSignedUrl, uuid } from './avatar';
import { friendly } from './errors';
import { supabase } from './supabase';
import { colors } from './theme';

const BUCKET = 'crests';
const SIDE = 512; // px do arquivo final
const MIN_SIDE = 128; // menor que isso fica borrado
const MAX_PICK_BYTES = 20 * 1024 * 1024; // antes de reduzir
const MAX_UPLOAD_BYTES = 1024 * 1024; // limite do bucket
const CACHE_SECONDS = '300'; // cache da CDN: escudo trocado ou removido some em até 5 min

async function removeFile(path: string | null) {
  if (path) await supabase.storage.from(BUCKET).remove([path]); // melhor esforço; o resto a limpeza apaga
}

/** Abre a galeria, prepara e envia o escudo. Devolve o novo caminho, ou null se o admin desistiu. */
export async function pickAndUploadCrest(peladaId: string): Promise<string | null> {
  const picked = await ImagePicker.launchImageLibraryAsync({
    mediaTypes: ['images'],
    allowsEditing: true,
    aspect: [1, 1],
    quality: 1,
  });
  if (picked.canceled || !picked.assets?.length) return null;
  const a = picked.assets[0];
  if (a.mimeType && !/^image\/(jpeg|png|heic|heif|webp)$/.test(a.mimeType)) {
    throw new Error('Use uma imagem JPG, PNG, HEIC ou WEBP.');
  }
  if (a.fileSize && a.fileSize > MAX_PICK_BYTES) throw new Error('Imagem muito grande (máximo 20 MB).');
  if (Math.min(a.width, a.height) < MIN_SIDE) throw new Error(`Imagem muito pequena (mínimo ${MIN_SIDE} × ${MIN_SIDE} px).`);

  const side = Math.min(a.width, a.height);
  const ctx = ImageManipulator.manipulate(a.uri);
  if (a.width !== a.height) {
    ctx.crop({ originX: Math.floor((a.width - side) / 2), originY: Math.floor((a.height - side) / 2), width: side, height: side });
  }
  if (side > SIDE) ctx.resize({ width: SIDE, height: SIDE });
  const rendered = await ctx.renderAsync();
  let ext: 'png' | 'jpg' = 'png';
  let body = await (await fetch((await rendered.saveAsync({ format: SaveFormat.PNG })).uri)).arrayBuffer();
  if (body.byteLength > MAX_UPLOAD_BYTES) {
    ext = 'jpg';
    body = await (await fetch((await rendered.saveAsync({ compress: 0.85, format: SaveFormat.JPEG })).uri)).arrayBuffer();
  }
  if (body.byteLength > MAX_UPLOAD_BYTES) throw new Error('Não foi possível reduzir o escudo para 1 MB. Tente outra imagem.');

  const path = `${peladaId}/${uuid()}.${ext}`;
  const up = await supabase.storage
    .from(BUCKET)
    .upload(path, body, { contentType: ext === 'png' ? 'image/png' : 'image/jpeg', upsert: false, cacheControl: CACHE_SECONDS });
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
    return <Image source={{ uri: url }} style={{ width: size, height: size }} contentFit="contain" accessibilityLabel={`Escudo de ${name}`} />;
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
