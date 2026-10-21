import { useEffect, useState } from 'react';
import { Platform } from 'react-native';
import Purchases, { PurchasesPackage } from 'react-native-purchases';

import { useAuth } from '../lib/session';
import { Body, Button, Card, ErrorText, Screen, Sub, Title } from '../lib/ui';

const KEY = Platform.select({
  ios: process.env.EXPO_PUBLIC_REVENUECAT_IOS_KEY,
  android: process.env.EXPO_PUBLIC_REVENUECAT_ANDROID_KEY,
});

export default function Premium() {
  const { session } = useAuth();
  const [pacotes, setPacotes] = useState<PurchasesPackage[]>([]);
  const [msg, setMsg] = useState<string | null>(null);
  const [ativo, setAtivo] = useState(false);

  useEffect(() => {
    (async () => {
      if (!KEY) return setMsg('Chave do RevenueCat ainda não configurada (EXPO_PUBLIC_REVENUECAT_IOS_KEY).');
      try {
        await Purchases.configure({ apiKey: KEY, appUserID: session?.user.id });
        const [offerings, info] = await Promise.all([Purchases.getOfferings(), Purchases.getCustomerInfo()]);
        setPacotes(offerings.current?.availablePackages ?? []);
        setAtivo(Object.keys(info.entitlements.active).length > 0);
      } catch (e) {
        setMsg(e instanceof Error ? e.message : String(e));
      }
    })();
  }, [session]);

  async function comprar(p: PurchasesPackage) {
    try {
      const { customerInfo } = await Purchases.purchasePackage(p);
      setAtivo(Object.keys(customerInfo.entitlements.active).length > 0);
    } catch (e) {
      const err = e as { userCancelled?: boolean; message?: string };
      if (!err.userCancelled) setMsg(err.message ?? 'Compra não concluída.');
    }
  }

  return (
    <Screen>
      <Title>Minuto 91 Premium</Title>
      <Sub>R$ 29,90 por mês, por pelada. Só o administrador contrata. No beta, o Premium é gratuito para todas as peladas.</Sub>
      {ativo && <Body>Premium ativo neste teste.</Body>}
      <ErrorText>{msg}</ErrorText>
      {pacotes.map((p) => (
        <Card key={p.identifier}>
          <Body>{p.product.title}</Body>
          <Sub>{p.product.priceString}</Sub>
          <Button title="Assinar (teste)" onPress={() => comprar(p)} />
        </Card>
      ))}
    </Screen>
  );
}
