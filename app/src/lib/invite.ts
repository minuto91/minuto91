// Convites (V4.1): link, mensagem e leitura do código colado. O token vem de create_pelada_invite (004):
// 64 caracteres hexadecimais, só o hash fica no banco, vale 7 dias e até 100 entradas.
//
// Link: sem domínio oficial, o link usa o esquema do app (minuto91://convite/<token> no app instalado;
// exp://... no Expo Go; http://localhost:8081/... na web). O WhatsApp não deixa link de esquema
// clicável, por isso a mensagem sempre leva o código e o caminho "Entrar com convite".
// Quando existir domínio com Universal Links / App Links, basta definir EXPO_PUBLIC_INVITE_BASE_URL
// (ex.: https://<domínio>) no .env/EAS: o link passa a ser https://<domínio>/convite/<token>.
import * as Linking from 'expo-linking';

const TOKEN = /[0-9a-f]{64}/i;

/** Acha o código de convite num texto colado (o código puro, o link ou a mensagem inteira). */
export function extractInviteToken(text: string): string | null {
  const m = text.match(TOKEN);
  return m ? m[0].toLowerCase() : null;
}

export function inviteLink(token: string) {
  const base = process.env.EXPO_PUBLIC_INVITE_BASE_URL?.trim().replace(/\/+$/, '');
  return base ? `${base}/convite/${token}` : Linking.createURL(`convite/${token}`);
}

export function inviteMessage(peladaName: string, token: string) {
  return (
    `Entra na nossa pelada "${peladaName}" no Minuto 91:\n${inviteLink(token)}\n\n` +
    `Se o link não abrir: instale o Minuto 91, toque em "Entrar com convite" e cole este código:\n${token}`
  );
}

/** Abre o WhatsApp com a mensagem pronta (wa.me funciona com ou sem o app instalado). */
export const whatsappUrl = (message: string) => `https://wa.me/?text=${encodeURIComponent(message)}`;
