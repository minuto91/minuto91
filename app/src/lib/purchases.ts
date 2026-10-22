// Assinatura Premium pela loja (RevenueCat), sempre ligada a UMA pelada (migração 026).
// Ordem da compra: 1) start_premium_purchase no banco (só o admin; recusa no beta, então não há
// cobrança real enquanto premium_beta_open = true); 2) atributo "pelada_id" no RevenueCat;
// 3) compra na loja; 4) o webhook avisa o banco, que é a fonte de verdade do Premium.
// O comprador na loja é sempre o id do usuário (appUserID), trocado no login/logout.
import { Linking, Platform } from 'react-native';
import Purchases, { PACKAGE_TYPE, PURCHASES_ERROR_CODE, PurchasesError, PurchasesPackage } from 'react-native-purchases';

import { friendly } from './errors';
import { supabase } from './supabase';

const KEY = Platform.select({
  ios: process.env.EXPO_PUBLIC_REVENUECAT_IOS_KEY,
  android: process.env.EXPO_PUBLIC_REVENUECAT_ANDROID_KEY,
});

/** Loja disponível neste aparelho (app instalado, com chave). Na web e sem chave, não. */
export const storeAvailable = Platform.OS !== 'web' && !!KEY;

let configuredFor: string | null = null;

/** Configura uma vez e mantém o comprador igual ao usuário logado. */
export async function ensurePurchases(userId: string) {
  if (!storeAvailable) throw new Error('A assinatura funciona só no app instalado pela App Store ou Google Play.');
  if (!(await Purchases.isConfigured())) {
    Purchases.configure({ apiKey: KEY!, appUserID: userId });
  } else if (configuredFor !== userId) {
    await Purchases.logIn(userId);
  }
  configuredFor = userId;
}

/** Chamar ao sair da conta, para a próxima pessoa não herdar o comprador. */
export async function resetPurchasesUser() {
  if (!storeAvailable || !configuredFor) return;
  configuredFor = null;
  try {
    if (!(await Purchases.isAnonymous())) await Purchases.logOut();
  } catch {
    // Sem rede: o próximo ensurePurchases faz logIn com o usuário certo.
  }
}

// A23: só o produto mensal da Pelada Premium. EXPO_PUBLIC_PREMIUM_PRODUCT_ID = id do produto na loja (o
// mesmo cadastrado em private.app_config.premium_product_ids, que o banco confere). Sem ele, só um pacote
// do tipo mensal com período de 1 mês é aceito. Nunca cai em "o primeiro pacote que vier".
const PRODUCT_ID = process.env.EXPO_PUBLIC_PREMIUM_PRODUCT_ID;

export async function loadPremiumPackage(userId: string): Promise<PurchasesPackage | null> {
  await ensurePurchases(userId);
  const offerings = await Purchases.getOfferings();
  const pkgs = offerings.current?.availablePackages ?? [];
  // No Android o identificador vem como "produto:plano"; compara a parte do produto.
  const sameProduct = (p: PurchasesPackage) => !PRODUCT_ID || p.product.identifier.split(':')[0] === PRODUCT_ID;
  const monthly = (p: PurchasesPackage) => p.packageType === PACKAGE_TYPE.MONTHLY && (p.product.subscriptionPeriod ?? 'P1M') === 'P1M';
  return pkgs.find((p) => sameProduct(p) && monthly(p)) ?? null;
}

/** "R$ 29,90 por mês", com o preço e o período que a loja devolveu (nada fixo). */
export function priceLabel(pkg: PurchasesPackage): string {
  const period = pkg.product.subscriptionPeriod;
  const per = period === 'P1M' ? 'por mês' : period ? `a cada ${period}` : 'por período';
  return `${pkg.product.priceString} ${per}`;
}

function storeMessage(e: unknown): string | null {
  const err = e as Partial<PurchasesError>;
  switch (err.code) {
    case PURCHASES_ERROR_CODE.PURCHASE_CANCELLED_ERROR:
      return null; // a pessoa desistiu: sem mensagem de erro
    case PURCHASES_ERROR_CODE.NETWORK_ERROR:
      return 'Sem conexão com a loja. Verifique a internet e tente de novo.';
    case PURCHASES_ERROR_CODE.PAYMENT_PENDING_ERROR:
      return 'Pagamento pendente na loja. O Premium é liberado quando a loja confirmar.';
    case PURCHASES_ERROR_CODE.PURCHASE_NOT_ALLOWED_ERROR:
      return 'Este aparelho ou conta da loja não permite compras.';
    case PURCHASES_ERROR_CODE.PRODUCT_ALREADY_PURCHASED_ERROR:
      return 'Sua conta da loja já tem esta assinatura. Use "Restaurar compras".';
    case PURCHASES_ERROR_CODE.STORE_PROBLEM_ERROR:
      return 'A loja teve um problema. Tente de novo em alguns minutos.';
  }
  return err.message ? friendly(err.message) : 'Compra não concluída.';
}

/**
 * Assina o Premium para a pelada. Devolve null se deu certo ou se a pessoa desistiu
 * (cancelled = true), ou a mensagem de erro.
 */
export async function subscribePelada(
  userId: string,
  peladaId: string,
  pkg: PurchasesPackage,
): Promise<{ error: string | null; cancelled: boolean }> {
  // 1) O banco confere admin, beta e "uma assinatura por conta da loja" ANTES de qualquer cobrança.
  const { error } = await supabase.rpc('start_premium_purchase', { p_pelada: peladaId });
  if (error) return { error: friendly(error.message), cancelled: false };
  try {
    await ensurePurchases(userId);
    // 2) O webhook usa este atributo para ligar a compra a esta pelada.
    await Purchases.setAttributes({ pelada_id: peladaId });
    // 3) Compra na loja.
    await Purchases.purchasePackage(pkg);
    return { error: null, cancelled: false };
  } catch (e) {
    // Compra não concluída: apaga o atributo para um evento futuro (renovação de outra pelada feita
    // direto na loja, por exemplo) não ser ligado a esta pelada por um atributo antigo. Quem chegou até
    // aqui não tem outra assinatura com período pago (start_premium_purchase recusaria).
    try {
      await Purchases.setAttributes({ pelada_id: '' });
    } catch {
      // melhor esforço
    }
    const msg = storeMessage(e);
    return { error: msg, cancelled: msg === null };
  }
}

/** Restaura compras da conta da loja (troca de aparelho ou reinstalação). */
export async function restorePurchases(userId: string): Promise<string | null> {
  try {
    await ensurePurchases(userId);
    await Purchases.restorePurchases();
    return null;
  } catch (e) {
    return storeMessage(e) ?? 'Restauração cancelada.';
  }
}

/** Abre o gerenciamento da assinatura (cancelar, trocar cartão) na loja. */
export async function openManageSubscription(userId: string): Promise<string | null> {
  try {
    await ensurePurchases(userId);
    if (Platform.OS === 'ios') {
      await Purchases.showManageSubscriptions();
      return null;
    }
    const info = await Purchases.getCustomerInfo();
    await Linking.openURL(info.managementURL ?? 'https://play.google.com/store/account/subscriptions');
    return null;
  } catch (e) {
    return storeMessage(e) ?? null;
  }
}
