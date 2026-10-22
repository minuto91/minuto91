// Foto do perfil (migração 027): bucket privado "avatars", arquivo <id do usuário>/<uuid>.jpg.
// A foto é escolhida na galeria (recorte quadrado nativo no celular; na web, recorte central),
// reduzida para 800 px em JPEG e exibida só por URL temporária assinada.
import { Image } from 'expo-image';
import { ImageManipulator, SaveFormat } from 'expo-image-manipulator';
import * as ImagePicker from 'expo-image-picker';
import { useEffect, useState } from 'react';
import { Text, View } from 'react-native';

import { friendly } from './errors';
import { supabase } from './supabase';
import { colors } from './theme';

const BUCKET = 'avatars';
const SIDE = 800; // px do arquivo final
const MIN_SIDE = 200; // foto menor que isso fica borrada na carta
const MAX_PICK_BYTES = 20 * 1024 * 1024; // antes de reduzir
const MAX_UPLOAD_BYTES = 2 * 1024 * 1024; // limite do bucket
const URL_TTL = 900; // segundos: link curto, porque um link assinado não pode ser revogado
const CACHE_SECONDS = '300'; // cache da CDN: foto trocada ou removida some em até 5 min

// Nome aleatório do arquivo (não é segredo: o acesso é controlado pelas políticas do bucket).
export function uuid() {
  const h = Array.from({ length: 32 }, () => Math.floor(Math.random() * 16).toString(16));
  h[12] = '4';
  h[16] = ((parseInt(h[16], 16) & 0x3) | 0x8).toString(16);
  const s = h.join('');
  return `${s.slice(0, 8)}-${s.slice(8, 12)}-${s.slice(12, 16)}-${s.slice(16, 20)}-${s.slice(20)}`;
}

async function removeFile(path: string | null) {
  if (path) await supabase.storage.from(BUCKET).remove([path]); // melhor esforço; o resto a limpeza apaga
}

/** Abre a galeria, prepara e envia a foto. Devolve false se a pessoa desistiu. */
export async function pickAndUploadAvatar(userId: string): Promise<boolean> {
  const picked = await ImagePicker.launchImageLibraryAsync({
    mediaTypes: ['images'],
    allowsEditing: true,
    aspect: [1, 1],
    quality: 1,
  });
  if (picked.canceled || !picked.assets?.length) return false;
  const a = picked.assets[0];
  if (a.mimeType && !/^image\/(jpeg|png|heic|heif|webp)$/.test(a.mimeType)) {
    throw new Error('Use uma foto JPG, PNG, HEIC ou WEBP.');
  }
  if (a.fileSize && a.fileSize > MAX_PICK_BYTES) throw new Error('Foto muito grande (máximo 20 MB).');
  if (Math.min(a.width, a.height) < MIN_SIDE) throw new Error(`Foto muito pequena (mínimo ${MIN_SIDE} × ${MIN_SIDE} px).`);

  const side = Math.min(a.width, a.height);
  const ctx = ImageManipulator.manipulate(a.uri);
  if (a.width !== a.height) {
    ctx.crop({ originX: Math.floor((a.width - side) / 2), originY: Math.floor((a.height - side) / 2), width: side, height: side });
  }
  if (side > SIDE) ctx.resize({ width: SIDE, height: SIDE });
  const rendered = await ctx.renderAsync();
  const saved = await rendered.saveAsync({ compress: 0.8, format: SaveFormat.JPEG });
  const body = await (await fetch(saved.uri)).arrayBuffer();
  if (body.byteLength > MAX_UPLOAD_BYTES) throw new Error('Não foi possível reduzir a foto para 2 MB. Tente outra.');

  const path = `${userId}/${uuid()}.jpg`;
  const up = await supabase.storage.from(BUCKET).upload(path, body, { contentType: 'image/jpeg', upsert: false, cacheControl: CACHE_SECONDS });
  if (up.error) throw new Error('Não foi possível enviar a foto. Verifique a internet e tente de novo.');
  const { data: old, error } = await supabase.rpc('set_my_avatar', { p_path: path });
  if (error) {
    await removeFile(path);
    throw new Error(friendly(error.message));
  }
  await removeFile(old as string | null);
  return true;
}

export async function removeAvatar() {
  const { data: old, error } = await supabase.rpc('clear_my_avatar');
  if (error) throw new Error(friendly(error.message));
  await removeFile(old as string | null);
}

// URLs assinadas ficam em memória até perto de vencer (chave: bucket + caminho).
const cache = new Map<string, { url: string; until: number }>();

/** URL assinada curta de um arquivo de bucket privado (fotos e escudos). */
export function useSignedUrl(bucket: string, path: string | null | undefined) {
  const key = path ? `${bucket}/${path}` : null;
  const cached = key ? cache.get(key)?.url : undefined;
  const [url, setUrl] = useState<{ path: string; url: string } | null>(null);

  useEffect(() => {
    if (!path || !key) return;
    const hit = cache.get(key);
    if (hit && hit.until > Date.now()) return;
    let alive = true;
    (async () => {
      const { data } = await supabase.storage.from(bucket).createSignedUrl(path, URL_TTL);
      if (!alive || !data?.signedUrl) return;
      cache.set(key, { url: data.signedUrl, until: Date.now() + (URL_TTL - 120) * 1000 });
      setUrl({ path, url: data.signedUrl });
    })();
    return () => {
      alive = false;
    };
  }, [bucket, key, path]);

  if (!path) return null;
  return url?.path === path ? url.url : (cached ?? null);
}

export const useAvatarUrl = (path: string | null | undefined) => useSignedUrl(BUCKET, path);

export const initials = (name: string) =>
  name
    .trim()
    .split(/\s+/)
    .slice(0, 2)
    .map((w) => w[0]?.toUpperCase() ?? '')
    .join('') || '?';

/** Foto redonda; sem foto (ou carregando), mostra as iniciais. */
export function Avatar({ path, name, size = 56 }: { path: string | null | undefined; name: string; size?: number }) {
  const url = useAvatarUrl(path);
  const box = { width: size, height: size, borderRadius: size / 2 };
  if (url) {
    return <Image source={{ uri: url }} style={box} contentFit="cover" accessibilityLabel={`Foto de ${name}`} />;
  }
  return (
    <View
      accessibilityLabel={`${name}, sem foto`}
      style={[box, { backgroundColor: colors.bg, borderWidth: 1, borderColor: colors.line, alignItems: 'center', justifyContent: 'center' }]}>
      <Text style={{ color: colors.deepBlue, fontWeight: '800', fontSize: size * 0.36 }}>{initials(name)}</Text>
    </View>
  );
}
